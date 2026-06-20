# Claude Code 最佳实践

> 系统级配置 - 适用于所有会话

## 核心原则

**Context 是最宝贵的资源**。填充越多，性能越差。主动管理上下文。

---

## 1. 给 Claude 验证方式

提供测试、截图或预期输出，让 Claude 能自我检查。

```bash
# 好：带测试用例
"实现 validateEmail 函数。测试：user@example.com → true, invalid → false"

# 差：无验证标准
"实现一个验证电子邮件地址的函数"
```

---

## 2. 先探索，再规划，最后编码

**小任务直接编码，大任务分四阶段：**

1. **探索** (Plan Mode) - 读取文件，理解现有结构
2. **规划** - 创建实现计划，按 `Ctrl+G` 编辑
3. **实现** (Normal Mode) - 按计划编码并验证
4. **提交** - 描述性提交并创建 PR

> 一句话能说清的修复，直接编码。

---

## 3. 提示要具体

| ❌ 模糊 | ✅ 具体 |
|--------|--------|
| "为 foo.py 添加测试" | "为 foo.py 编写测试，涵盖用户已注销的边界情况。避免使用 mocks。" |
| "为什么 API 这么奇怪？" | "查看 ExecutionFactory 的 git 历史记录，总结其 API 是如何演变的" |
| "添加日历小部件" | "参照 HotDogWidget.php 的模式实现日历小部件，让用户选择月份和年份。" |

**技巧：**
- 用 `@` 引用文件而非描述位置
- 粘贴截图/图像直接提供视觉上下文
- 提供 URL 用于文档参考
- 让 Claude 用 Bash/MCP 自己拉取上下文

---

## 4. 配置环境

### CLAUDE.md
- 只包括 Claude 无法从代码推断的内容
- 保持简洁，每条问自己："删除会导致 Claude 出错吗？"
- 使用 `@path/to/file` 语法导入其他文件

### 权限配置
- 用 `/permissions` 白名单安全命令
- 用 `/sandbox` 启用操作系统级隔离
- 仅在无网沙箱中使用 `--dangerously-skip-permissions`

### CLI 工具
- 优先使用 `gh`、`aws`、`gcloud` 等 CLI 工具
- 比直接 API 调用更高效、速率限制更少

---

## 5. 沟通技巧

### 代码库问题
问 Claude 你会问资深工程师的问题：
- "日志记录如何工作？"
- "`foo.rs:134` 的 `async move { ... }` 是什么意思？"

### 让 Claude 采访你
```
"我想构建 [简述]。用 AskUserQuestion 工具详细采访我，
涵盖技术实现、UI/UX、边界情况和权衡。"
```

---

## 6. 会话管理

### 及时纠正方向
- `Esc` - 停止当前操作
- `Esc + Esc` 或 `/rewind` - 打开检查点菜单
- `/clear` - 重置不相关任务间的上下文

> 同一问题纠正两次后，运行 `/clear` 用更好的提示重新开始

### 积极管理上下文
- 不相关任务间频繁使用 `/clear`
- 自动压缩保留重要代码和决策
- 用 `/compact <instructions>` 自定义压缩

---

## 7. 扩展技巧

### Headless 模式
```bash
claude -p "解释这个项目的作用"                    # 一次性查询
claude -p "列出所有 API 端点" --output-format json  # 结构化输出
```

### 并行会话
- **Writer/Reviewer 模式**：会话 A 编码，会话 B 审查
- **测试先行**：一个会话写测试，另一个写代码通过

### 扇出批量操作
```bash
for file in $(cat files.txt); do
  claude -p "迁移 $file 到 Vue" --allowedTools "Edit,Bash(git commit *)"
done
```

---

## 8. 避免的陷阱

| 陷阱 | 修复 |
|------|------|
| 厨房水槽会话 | 用 `/clear` 分隔不相关任务 |
| 重复纠正 | `/clear` 后用更好的提示重开 |
| CLAUDE.md 过于冗长 | 无情修剪，将规则转为 hook |
| 信任但未验证 | 始终提供验证（测试/脚本/截图） |
| 无限探索 | 狭隘限定范围或用 subagents |

---

## 相关命令速查

| 命令 | 用途 |
|------|------|
| `/init` | 生成启动 CLAUDE.md |
| `/permissions` | 配置权限白名单 |
| `/sandbox` | 启用沙箱 |
| `/hooks` | 交互式配置 hooks |
| `/clear` | 清空上下文 |
| `/rewind` | 恢复检查点 |
| `/rename` | 重命名会话 |
| `/compact` | 压缩对话 |
| `/plugin` | 浏览插件市场 |

---

> 完整文档：https://code.claude.com/docs
