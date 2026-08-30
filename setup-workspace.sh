#!/usr/bin/env bash
set -euo pipefail

OLD_REPO="/home/suhailps/latest_claude/ayma"
NEW_ROOT="$(pwd)"

cp "$OLD_REPO/docs/rewrite-AGENTS.md"       "$NEW_ROOT/AGENTS.md"
cp "$OLD_REPO/docs/rewrite-PLAN.md"         "$NEW_ROOT/PLAN.md"
mkdir -p "$NEW_ROOT/docs"
cp "$OLD_REPO/docs/rewrite-architecture.md" "$NEW_ROOT/docs/ARCHITECTURE.md"

mkdir -p "$NEW_ROOT/ayma_flutter/scripts"
cp "$OLD_REPO/ayma_flutter/scripts/adb-ui"             "$NEW_ROOT/ayma_flutter/scripts/adb-ui"
cp "$OLD_REPO/ayma_flutter/scripts/check-flutter-env"  "$NEW_ROOT/ayma_flutter/scripts/check-flutter-env"
chmod +x "$NEW_ROOT/ayma_flutter/scripts/adb-ui" "$NEW_ROOT/ayma_flutter/scripts/check-flutter-env"
sed -i "s|${OLD_REPO}|${NEW_ROOT}|g" \
  "$NEW_ROOT/ayma_flutter/scripts/adb-ui" \
  "$NEW_ROOT/ayma_flutter/scripts/check-flutter-env"

mkdir -p "$NEW_ROOT/.agents/skills/flutter_ui_design" \
         "$NEW_ROOT/.agents/skills/flutter_debugging" \
         "$NEW_ROOT/.agents/skills/ai_engineering_tdd"
cp "$OLD_REPO/.agents/skills/flutter_ui_design/SKILL.md" "$NEW_ROOT/.agents/skills/flutter_ui_design/SKILL.md"
cp "$OLD_REPO/.agents/skills/flutter_debugging/SKILL.md" "$NEW_ROOT/.agents/skills/flutter_debugging/SKILL.md"
cp "$OLD_REPO/.agents/skills/ai_engineering_tdd/SKILL.md" "$NEW_ROOT/.agents/skills/ai_engineering_tdd/SKILL.md"

echo "Done. Copied into: $NEW_ROOT"
echo "  AGENTS.md, PLAN.md, docs/ARCHITECTURE.md"
echo "  ayma_flutter/scripts/{adb-ui,check-flutter-env} (paths rewritten to $NEW_ROOT)"
echo "  .agents/skills/{flutter_ui_design,flutter_debugging,ai_engineering_tdd}/SKILL.md"
