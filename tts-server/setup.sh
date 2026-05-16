#!/usr/bin/env bash
# 一键安装：Python 3.11 venv + xzjosh Taffy-Bert-VITS2 v2.3 (ModelScope studio)。
# 第一次跑大约 15-30 分钟，主要时间在 git-lfs 拉 ~4GB 模型（728MB G_11100 + ~3.5GB BERT）。
#
# 为什么用 modelscope studio 而不是 fishaudio mainline + HF：
# - xzjosh 没把 Taffy v2.3 checkpoint 单独发到 HuggingFace（验证过：HF /api/models?author=XzJosh 返回空）。
#   checkpoint 只在 modelscope studio 仓库 (https://www.modelscope.cn/studios/xzjosh/Taffy-Bert-VITS2-2.3)
#   里 LFS 托管。
# - studio 仓库自带：v2.3 代码、Data/Taffy/models/G_11100.pth、三个 BERT 子模型 (bert/...)。
#   一次 clone + lfs pull 就齐了，不用再 transformers AutoModel.from_pretrained 单独下 BERT。
# - 顺便：v1.x cleaner 只注册 ZH，英文字符在 chinese.py 被 regex 删掉，所以必须 v2.3。
#
# 前置：
#   brew install python@3.11 ffmpeg git-lfs
#
# 用法：
#   cd /Users/xixi/Code/pet/tts-server
#   ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Library/Application Support/Pet/tts-server"

# Bert-VITS2 pin 死 torch==2.2 / transformers==4.36，3.12+ 没现成 wheel，老老实实用 3.11
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.11}"
STUDIO_REPO="https://www.modelscope.cn/studios/xzjosh/Taffy-Bert-VITS2-2.3.git"

echo "==> Pet TTS 安装器 (Bert-VITS2 Taffy v2.3)"
echo "    目标目录：$DEST"
echo "    源文件夹：$SCRIPT_DIR"
echo "    Python：$PYTHON_BIN"

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "❌ 没找到 $PYTHON_BIN"
    echo "   先装：brew install python@3.11"
    exit 1
fi
for tool in ffmpeg git git-lfs; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "❌ 没找到 $tool"
        echo "   先装：brew install $tool"
        exit 1
    fi
done

mkdir -p "$DEST"
cd "$DEST"

# 1. venv
if [[ ! -d venv ]]; then
    echo "==> 建 venv (Python 3.11)"
    "$PYTHON_BIN" -m venv venv
fi
# shellcheck disable=SC1091
source venv/bin/activate
python -m pip install --upgrade pip wheel

# 2. clone ModelScope studio 仓库（代码 + 模型在同一个 repo 里，LFS 托管）
#    SKIP_SMUDGE：先只拉小文件，下面手动 lfs pull 才好看进度
#    检测早期 fishaudio mainline 装的残骸（没 .git/，或 origin 不是 modelscope）→ 重新来
if [[ -d Bert-VITS2 ]]; then
    EXISTING_REMOTE="$(cd Bert-VITS2 && git config --get remote.origin.url 2>/dev/null || true)"
    if [[ "$EXISTING_REMOTE" != *modelscope.cn* ]]; then
        echo "==> 检测到旧版 Bert-VITS2（remote=$EXISTING_REMOTE），删掉重来"
        rm -rf Bert-VITS2
    fi
fi
if [[ ! -d Bert-VITS2 ]]; then
    echo "==> clone studio 仓库（只拉代码，模型走 lfs）"
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth=1 "$STUDIO_REPO" Bert-VITS2
fi

# 3. lfs pull —— Data/Taffy/models/G_*.pth (728MB) + bert/*/pytorch_model.bin (~3.5GB)
echo "==> git lfs pull（首次 ~4GB，可能 10 分钟）"
( cd Bert-VITS2 && git lfs pull )

# 4. 关键库 pin 死 —— Bert-VITS2 自家 requirements 不 pin 这些，pip 会装到 transformers 5.x /
#    numpy 2.x，跟老代码 API + ABI 都裂
echo "==> pin 关键库版本"
pip install \
    "torch==2.2.2" \
    "torchaudio==2.2.2" \
    "transformers==4.36.2" \
    "numpy<2.0" \
    "scipy>=1.10,<1.13"

# 5. 安装 studio 自带 requirements.txt（如果有）。跳过 WeTextProcessing：
#    它依赖 pynini → OpenFST C++ headers，Mac 上编译很折腾，
#    而 Bert-VITS2 推理不强依赖（只是 ZH 文本归一化的可选优化）
echo "==> 安装 studio 仓库依赖（跳过 WeTextProcessing）"
if [[ -f Bert-VITS2/requirements.txt ]]; then
    grep -v -i 'wetextprocessing' Bert-VITS2/requirements.txt > /tmp/bertvits2-reqs.txt
    pip install -r /tmp/bertvits2-reqs.txt
fi

# 6. server 这一层额外的依赖（FastAPI + ffmpeg-python 用来 encode mp3）
echo "==> 安装 server 额外依赖"
pip install \
    "fastapi==0.110.0" \
    "uvicorn[standard]==0.27.1" \
    "pydantic>=2.0,<3.0" \
    "ffmpeg-python==0.2.0"

# 7. 把 server.py 拷进 Bert-VITS2/ —— 让它能直接 `from infer import ...` / `from tools.sentence import ...`
cp "$SCRIPT_DIR/server.py" Bert-VITS2/server.py
echo "    server.py 已复制到 Bert-VITS2/"

# 8. 自检：确认必要文件都到位
echo "==> 自检"
MISSING=()
[[ -f Bert-VITS2/infer.py ]] || MISSING+=("Bert-VITS2/infer.py")
[[ -f Bert-VITS2/utils.py ]] || MISSING+=("Bert-VITS2/utils.py")
[[ -f Bert-VITS2/tools/sentence.py ]] || MISSING+=("Bert-VITS2/tools/sentence.py")
[[ -f Bert-VITS2/Data/Taffy/config.json ]] || MISSING+=("Bert-VITS2/Data/Taffy/config.json")
if ! ls Bert-VITS2/Data/Taffy/models/G_*.pth >/dev/null 2>&1; then
    MISSING+=("Bert-VITS2/Data/Taffy/models/G_*.pth")
fi
for sub in chinese-roberta-wwm-ext-large deberta-v2-large-japanese-char-wwm deberta-v3-large; do
    [[ -d Bert-VITS2/bert/$sub ]] || MISSING+=("Bert-VITS2/bert/$sub")
done
if (( ${#MISSING[@]} > 0 )); then
    echo "⚠️  下面这些缺了，可能 lfs pull 没成功："
    for m in "${MISSING[@]}"; do echo "     - $m"; done
    echo "   重跑：cd \"$DEST/Bert-VITS2\" && git lfs pull"
    exit 1
fi

echo ""
echo "✅ 装好了。"
echo "   测试启动："
echo "     cd \"$DEST/Bert-VITS2\""
echo "     source ../venv/bin/activate"
echo "     python server.py"
echo "   App 端在 Settings 里切到「本地 Taffy」即可自动拉起。"
