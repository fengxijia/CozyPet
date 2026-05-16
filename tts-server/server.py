"""FastAPI wrapper for xzjosh Taffy Bert-VITS2 v2.3.

运行环境：
- setup.sh 会把 `https://www.modelscope.cn/studios/xzjosh/Taffy-Bert-VITS2-2.3.git` 整个
  clone 到 `~/Library/Application Support/Pet/tts-server/Bert-VITS2/`，再 git lfs pull。
  studio 仓库自带：
    - 代码（包括 infer.py / tools/sentence.py / text/*）
    - 模型权重：Data/Taffy/models/G_*.pth
    - 三个 BERT 子模型：bert/{chinese-roberta-wwm-ext-large, deberta-v2-large-japanese-char-wwm, deberta-v3-large}
  所以这一份 server.py 必须放在那个目录里跑（cwd=Bert-VITS2/），相对路径才对得上。
- 监听 127.0.0.1:47322，Mac App 通过 LocalBertVITS2TTS 调它。

为什么走 v2.3 而不是 v1.x：
- v1.x 的 cleaner 只注册了 ZH，英文字符在 text/chinese.py 里被 regex 直接删掉 —— 这是
  ModelScope demo「英文整段消失」的根本原因；而 v1.x 模型也只在中文音素上训练，
  喂英文音素出来也是噪声。
- v2.3 cleaner 同时注册 ZH/JP/EN，配套有 tools.sentence.split_by_language 做自动语种检测；
  xzjosh 也专门发了 v2.3 Taffy checkpoint（Data/Taffy/models/G_11100.pth, 728MB），
  在 modelscope studio 仓库里 LFS 托管。所以 v2.3 是唯一能同时还原音色 + 念英文的路。

环境变量（可选）：
- PET_TTS_MODEL_DIR  覆盖 Data/Taffy 的位置（要求里面有 models/G_*.pth + config.json）
- PET_TTS_DEVICE     "cpu" / "mps" / "cuda"，默认 cpu
- PET_TTS_PORT       覆盖 47322

设计要点：
- 模型 lazy load：startup 时另起线程加载，/health 在加载完之前返回 loading；
  这样 Swift 端能轮询 /health 一直转圈，不会因为模型加载阻塞 fastapi 启动。
- 单实例 + 互斥锁：v2.3 net_g 内部状态仍不是线程安全的，并发请求串行化。
- 中英日混排：tools.sentence.split_by_language 已经做完了，逐段喂 infer() 拼接。
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
import threading
from pathlib import Path

import numpy as np
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("pet-tts")

DEFAULT_MODEL_DIR = HERE / "Data" / "Taffy"
MODEL_DIR = Path(os.environ.get("PET_TTS_MODEL_DIR", DEFAULT_MODEL_DIR))
DEVICE = os.environ.get("PET_TTS_DEVICE", "cpu")
PORT = int(os.environ.get("PET_TTS_PORT", "47322"))


class ModelState:
    """全局单例。Bert-VITS2 v2.3 的 net_g 不是线程安全的，所有合成请求拿同一把锁。"""

    def __init__(self) -> None:
        self.hps = None
        self.net_g = None
        self.ready = False
        self.error: str | None = None
        self.lock = threading.Lock()
        self.load_started = False

    def load(self) -> None:
        """加载 config + checkpoint。重的事在这里发生（CPU 上 ~30s）。"""
        if self.ready or self.load_started:
            return
        self.load_started = True
        try:
            log.info("loading Bert-VITS2 v2.3 from %s on %s", MODEL_DIR, DEVICE)
            import utils  # type: ignore  # noqa: E402  studio 自带
            from infer import get_net_g, latest_version  # type: ignore  # noqa: E402

            config_path = MODEL_DIR / "config.json"
            if not config_path.exists():
                raise FileNotFoundError(f"找不到 config.json：{config_path}")

            # 优先 Data/Taffy/models/G_*.pth；找不到再 fall back 到 Data/Taffy/G_*.pth
            search_dirs = [MODEL_DIR / "models", MODEL_DIR]
            ckpts: list[Path] = []
            for d in search_dirs:
                if d.is_dir():
                    found = list(d.glob("G_*.pth"))
                    if found:
                        ckpts = found
                        break
            if not ckpts:
                raise FileNotFoundError(f"找不到 G_*.pth，看过：{search_dirs}")
            # 取 step 数最大的（G_11100 比 G_8000 新）
            def _step(p: Path) -> int:
                try:
                    return int(p.stem.split("_", 1)[1])
                except (ValueError, IndexError):
                    return 0
            ckpt_path = max(ckpts, key=_step)

            hps = utils.get_hparams_from_file(str(config_path))
            version = getattr(hps, "version", None) or latest_version
            net_g = get_net_g(str(ckpt_path), version, DEVICE, hps)

            self.hps = hps
            self.net_g = net_g
            self.ready = True
            log.info("model loaded ✓ (ckpt=%s, version=%s)", ckpt_path.name, version)
        except Exception as e:  # noqa: BLE001
            self.error = f"{type(e).__name__}: {e}"
            log.exception("model load failed")


STATE = ModelState()


def _split_pieces(text: str) -> list[tuple[str, str]]:
    """[(piece_text, LANG), ...]；LANG ∈ {ZH, JP, EN}。"""
    from tools.sentence import split_by_language  # type: ignore  # noqa: E402

    out: list[tuple[str, str]] = []
    for piece, lang in split_by_language(text, target_languages=["zh", "ja", "en"]):
        piece = piece.strip()
        if not piece:
            continue
        L = lang.upper()
        if L == "JA":  # studio 内部 cleaner 用 JP，detector 用 JA
            L = "JP"
        if L not in ("ZH", "JP", "EN"):
            L = "ZH"
        out.append((piece, L))
    return out


def _infer_piece(text: str, language: str) -> np.ndarray:
    """单段合成 → float32 numpy 波形。"""
    from infer import infer  # type: ignore  # noqa: E402

    if STATE.hps is None or STATE.net_g is None:
        raise RuntimeError("model not loaded")
    # 单 speaker 模型：spk2id = {"Taffy": 0} 之类，取第一个 key
    sid = next(iter(STATE.hps.data.spk2id.keys()))

    with torch.no_grad():
        audio = infer(
            text,
            emotion=None,
            sdp_ratio=0.5,
            noise_scale=0.6,
            noise_scale_w=0.9,
            length_scale=1.0,
            sid=sid,
            language=language,
            hps=STATE.hps,
            net_g=STATE.net_g,
            device=DEVICE,
        )
    return np.asarray(audio, dtype=np.float32)


def _encode_mp3(audio: np.ndarray, sample_rate: int) -> bytes:
    """numpy float32 → mp3 bytes。"""
    import ffmpeg  # type: ignore  # noqa: E402

    audio = np.clip(audio, -1.0, 1.0)
    pcm = (audio * 32767).astype(np.int16).tobytes()
    out, _ = (
        ffmpeg.input(
            "pipe:0",
            format="s16le",
            acodec="pcm_s16le",
            ar=sample_rate,
            ac=1,
        )
        .output("pipe:1", format="mp3", audio_bitrate="128k")
        .run(input=pcm, capture_stdout=True, capture_stderr=True, quiet=True)
    )
    return out


app = FastAPI(title="Pet TTS (Bert-VITS2 Taffy v2.3)")


class TTSReq(BaseModel):
    text: str


@app.get("/health")
def health() -> dict:
    if STATE.error:
        return {"status": "error", "error": STATE.error}
    if STATE.ready:
        return {"status": "ready"}
    return {"status": "loading" if STATE.load_started else "idle"}


@app.on_event("startup")
def _kickoff_load() -> None:
    threading.Thread(target=STATE.load, daemon=True).start()


@app.post("/tts")
async def tts(req: TTSReq) -> Response:
    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text 为空")

    # 等模型 ready；至多 90s（首次冷启可能要 30s+）
    if not STATE.ready:
        for _ in range(90):
            if STATE.ready or STATE.error:
                break
            await asyncio.sleep(1.0)
    if STATE.error:
        raise HTTPException(status_code=503, detail=f"模型加载失败：{STATE.error}")
    if not STATE.ready:
        raise HTTPException(status_code=503, detail="模型还在加载，请稍后重试")

    pieces = _split_pieces(text)
    if not pieces:
        raise HTTPException(status_code=400, detail="切完没有可念的内容")

    sr = STATE.hps.data.sampling_rate  # type: ignore[union-attr]
    silence = np.zeros(int(sr * 0.12), dtype=np.float32)

    def _synth() -> bytes:
        chunks: list[np.ndarray] = []
        with STATE.lock:
            for i, (piece, lang) in enumerate(pieces):
                log.info("synth [%d/%d] %s: %r", i + 1, len(pieces), lang, piece)
                chunks.append(_infer_piece(piece, lang))
                if i < len(pieces) - 1:
                    chunks.append(silence)
        audio = np.concatenate(chunks)
        return _encode_mp3(audio, sr)

    loop = asyncio.get_event_loop()
    try:
        mp3 = await loop.run_in_executor(None, _synth)
    except Exception as e:  # noqa: BLE001
        log.exception("synthesize failed")
        raise HTTPException(status_code=500, detail=f"合成失败：{e}") from e

    return Response(content=mp3, media_type="audio/mpeg")


if __name__ == "__main__":
    import uvicorn  # type: ignore

    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")
