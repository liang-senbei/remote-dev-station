#!/bin/bash
# PostToolUse Hook - 在 Edit/Write 后运行类型检查
if [ -f "package.json" ]; then
  if [ -f "tsconfig.json" ]; then
    echo "🔍 正在运行 TypeScript 类型检查..."
    npx tsc --noEmit 2>&1 | head -20
    if [ $? -ne 0 ]; then echo "⚠️  类型检查发现问题，建议修复后再提交"; fi
  fi
  if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f "eslint.config.js" ]; then
    echo "🔍 正在运行 ESLint 检查..."
    npx eslint --ext .js,.jsx,.ts,.tsx . 2>&1 | head -10
  fi
  if [ -f ".prettierrc" ] || [ -f ".prettierrc.js" ] || [ -f "prettier.config.js" ]; then
    echo "🔍 正在检查代码格式..."
    npx prettier --check . 2>&1 | head -10
  fi
fi
exit 0
