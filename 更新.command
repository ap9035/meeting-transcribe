#!/bin/bash
# ==========================================================================
#  更新工具 —— 有新版本時，雙擊這支就能更新到最新版
#  會自動保留你在「bin/人名對照表.txt」等檔案上做的修改，更新完不用重裝。
# ==========================================================================
set -u
set -o pipefail

APP_DIR="$HOME/Library/Application Support/MeetingTranscribe"
VENV="$APP_DIR/venv"
REPO_URL="https://github.com/ap9035/meeting-transcribe.git"

# 找出程式本體的位置（可能是原始資料夾，也可能是桌面上的捷徑）
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$HERE/.git" ]; then
  SAVED="$(cat "$APP_DIR/install_path.txt" 2>/dev/null || echo "")"
  if [ -n "$SAVED" ] && [ -d "$SAVED/.git" ]; then
    HERE="$SAVED"
  else
    # 資料夾被搬走或改名了 → 在常見位置找一下，找到就順手把記錄修好
    FOUND="$(find "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
               -maxdepth 3 -path '*/bin/transcribe.py' -print -quit 2>/dev/null)"
    if [ -n "$FOUND" ]; then
      HERE="$(cd "$(dirname "$FOUND")/.." && pwd)"
    fi
  fi
fi
# 每次更新都把位置重新記一次，桌面捷徑才不會因為資料夾搬家就失效
[ -f "$HERE/bin/transcribe.py" ] && printf '%s\n' "$HERE" > "$APP_DIR/install_path.txt" 2>/dev/null

alert() {  # 標題, 內容
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"好\"} default button 1 with icon note" >/dev/null 2>&1
}

cd "$HERE" 2>/dev/null || {
  alert "更新失敗" "找不到程式資料夾，請確認「安裝.command」有沒有跑過。"
  exit 1
}

clear
echo "=========================================="
echo "  會議逐字稿工具 · 更新程式"
echo "=========================================="
echo
echo "資料夾：$HERE"
echo

if ! command -v git >/dev/null 2>&1; then
  echo "這台電腦沒有安裝 git，無法自動更新。"
  echo
  echo "補裝方法（Apple 官方工具，免費）："
  echo "  1. 按 Command(⌘)+空白鍵，輸入「終端機」按 Enter"
  echo "  2. 貼上這一行按 Enter：  xcode-select --install"
  echo "  3. 跳出視窗按「安裝」→「同意」，等它裝完（約 5～20 分鐘）"
  echo "  4. 裝好之後，再點一次桌面的「🔄 更新工具」"
  echo
  alert "更新失敗" "這台電腦沒有安裝 git，無法自動更新。請看視窗裡的說明補裝 git（xcode-select --install），裝好再點一次更新。"
  read -r -p "按 Enter 關閉…"
  exit 1
fi

if [ ! -d "$HERE/.git" ]; then
  echo "這個資料夾不是用「git clone」下載的，無法自動更新。"
  echo "請改用下面指令重新下載一份，再把 bin/人名對照表.txt 的內容搬過去："
  echo
  echo "  git clone $REPO_URL"
  echo
  alert "更新失敗" "這個資料夾不是用 git clone 下載的，無法自動更新。"
  read -r -p "按 Enter 關閉…"
  exit 1
fi

echo "[1/3] 確認目前分支…"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "      ✗ Git 狀態異常（detached HEAD），無法自動更新。"
  alert "更新失敗" "Git 狀態異常，請找當初幫你安裝的人協助處理。"
  read -r -p "按 Enter 關閉…"
  exit 1
fi
echo "      ✓ 目前在「$BRANCH」分支"

echo
echo "[2/3] 下載並套用最新版本…"
STASHED=0
if [ -n "$(git status --porcelain)" ]; then
  echo "      偵測到本機有修改（例如人名對照表），先暫存起來…"
  if git stash push -u -m "更新前自動暫存 $(date '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1; then
    STASHED=1
  fi
fi

BEFORE="$(git rev-parse HEAD)"
if ! git pull --ff-only origin "$BRANCH" 2>&1 | tail -10; then
  echo
  echo "      ✗ 更新失敗（可能是網路問題，或本機分支跟遠端分岔了）。"
  if [ "$STASHED" -eq 1 ]; then
    git stash pop >/dev/null 2>&1
    echo "      已還原你剛剛的本機修改。"
  fi
  alert "更新失敗" "無法下載或套用最新版本，請檢查網路連線，或找當初幫你安裝的人協助處理。"
  read -r -p "按 Enter 關閉…"
  exit 1
fi
AFTER="$(git rev-parse HEAD)"
echo "      ✓ 完成"

STASH_CONFLICT=0
if [ "$STASHED" -eq 1 ]; then
  echo
  echo "      還原剛剛暫存的本機修改…"
  if git stash pop 2>&1 | tail -10; then
    echo "      ✓ 已還原"
  else
    STASH_CONFLICT=1
    echo "      ⚠️ 還原時發生衝突。你的修改還安全地留在「git stash」裡，沒有遺失，"
    echo "         但需要手動處理才能套用回去，請找當初幫你安裝的人協助（指令：git stash list）。"
  fi
fi

if [ "$BEFORE" = "$AFTER" ]; then
  echo
  echo "已經是最新版本，不需要更新。"
  alert "已是最新版本" "目前已經是最新版本，不需要更新。"
  read -r -p "按 Enter 關閉…"
  exit 0
fi

echo
echo "[3/3] 更新語音辨識套件（如果版本有異動）…"
if [ -x "$VENV/bin/python" ]; then
  UV="$HOME/.local/bin/uv"
  [ -x "$UV" ] || UV="$(command -v uv 2>/dev/null || true)"
  if [ -n "$UV" ]; then
    "$UV" pip install --python "$VENV/bin/python" \
      "faster-whisper>=1.2" "pyannote.audio>=4.0" "opencc-python-reimplemented" 2>&1 \
      | grep -Ei "error|Installed|Prepared" | tail -5 || true
    echo "      ✓ 完成"
  else
    echo "      找不到 uv，略過套件更新（通常不影響使用）。"
  fi
else
  echo "      尚未安裝過語音環境，略過（請先執行「安裝.command」）。"
fi

# 解除「從網路下載」的隔離標記，不然 macOS 會擋著不給雙擊。
# 注意：有些 macOS 版本的 xattr 不支援 -r，所以用 find 一個一個處理才保險。
unquarantine() {
  [ -e "$1" ] || return 0
  find "$1" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null
  return 0
}

unquarantine "$HERE"
chmod +x "$HERE/點這裡兩下執行逐字稿程式.command" "$HERE/安裝.command" "$HERE/更新.command" 2>/dev/null

echo
if [ "$STASH_CONFLICT" -eq 1 ]; then
  echo "=========================================="
  echo "  更新完成，但有一項衝突待處理 ⚠️"
  echo "=========================================="
  echo
  echo "目前版本：$(git log -1 --format='%h %s' 2>/dev/null)"
  echo "程式本身已是最新版，但你先前的本機修改沒能自動套用回去，見上方說明。"
  alert "更新完成（有衝突待處理）" "程式已更新，但你的本機修改（例如人名對照表）跟新版本衝突，需要手動處理，請找當初幫你安裝的人協助。"
else
  echo "=========================================="
  echo "  更新完成 🎉"
  echo "=========================================="
  echo
  echo "目前版本：$(git log -1 --format='%h %s' 2>/dev/null)"
  alert "更新完成" "已經更新到最新版本，可以繼續使用「📝 點這裡兩下執行逐字稿程式」。"
fi
echo
read -r -p "按 Enter 關閉…"
