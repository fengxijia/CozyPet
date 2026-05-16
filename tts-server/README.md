# Pet TTS — 本地 Bert-VITS2 Taffy 服务

Pet 桌宠的本地 TTS 后端：跑 [xzjosh 的永雏塔菲 Bert-VITS2 v2.3](https://www.modelscope.cn/studios/xzjosh/Taffy-Bert-VITS2-2.3)，外面套一层 FastAPI。

走 v2.3 而不是 ModelScope 上更常见的 v1.x 是因为：v1.x cleaner 只注册 ZH，`text/chinese.py` 里直接 `re.sub('[a-zA-Z]+', '', seg)` 把英文删了 —— 这是 demo「英文整段消失」的根本原因。v2.3 cleaner 同时支持 ZH/JP/EN，且 xzjosh 在 studio 仓库里 LFS 托管了配套的 v2.3 Taffy checkpoint。

## 一键装

```bash
cd tts-server
./setup.sh
```

要的东西：
- `brew install python@3.11 ffmpeg git-lfs`
- 大概 ~6GB 磁盘（studio 仓库 LFS 模型 + venv）
- 大概 15-30 分钟（主要在 git-lfs 拉 ~4GB 模型）

装完后所有东西在 `~/Library/Application Support/Pet/tts-server/`。studio 仓库 clone 到 `Bert-VITS2/`，里面已经自带：v2.3 代码、`Data/Taffy/models/G_11100.pth` (728MB)、`bert/*` 三个 BERT 子模型。

## 手动启

```bash
cd ~/Library/Application\ Support/Pet/tts-server/Bert-VITS2
source ../venv/bin/activate
python server.py
```

正常情况下 Pet_app 启动时会自动把它拉起来（看 Settings → 语音）。

## API

`POST http://127.0.0.1:47322/tts`
```json
{ "text": "你好 hello 今天" }
```
返回 `audio/mpeg`（mp3 bytes）。

`GET http://127.0.0.1:47322/health` → `{"status":"ready"|"loading"|"error"}`

## 环境变量

| 名称 | 默认 | 含义 |
|---|---|---|
| `PET_TTS_PORT` | 47322 | 监听端口 |
| `PET_TTS_DEVICE` | cpu | `cpu` / `mps` / `cuda`（mps 当前不稳，慎用） |
| `PET_TTS_MODEL_DIR` | `./Data/Taffy` | checkpoint 目录 |

## 已知问题

- M-series Mac CPU 推理大概 1-2x realtime（5s 音频 ≈ 5-10s 合成）。Swift 端的 `CachingTTSProvider` 会自动缓存重复句子。
- 首次请求会触发模型加载（30-60s），期间 `/tts` 会等到模型 ready。
- 单 worker 串行处理：Bert-VITS2 推理不是线程安全的，请求来了就排队。

## License 注意

- Bert-VITS2 框架：MIT
- xzjosh 的 Taffy 训练权重：fan-made，仅限个人非商用使用
