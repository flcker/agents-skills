# NVIDIA 驱动版本核对记录

已核对结论的沉淀记录（核对日期：2026-11-20）。这是**可追加的记录表，不是权威结论**——官方 release notes 会更新，结论可能过期。使用前建议先跑 `fetch-release-notes.mjs` 复核最新官方原文。

| 版本 | Open Issues（官方原文，核对于 2026-11-20） | 备注 |
|---|---|---|
| 617.42 | 仅 1 条：`"Prefer Maximum Performance" Power Management Mode may not be applied correctly [6007998]` | 官方 open issue 唯一一条，属功耗调优类，判为良性。 |
| 610.88 | 同上，同样只有 `6007998` 一条 | 与 617.42 一致。 |
| 621.14 | 官方写 `N/A` | **官方列表不可信**：实测崩溃 + 媒体实锤写盘 bug，官方"无 open issue"不代表安全。 |

## 说明

- 上表"官方原文"均来自 NVIDIA 官方 release notes PDF 的 `3.2 Open Issues` 小节。
- 621.14 的写盘 bug 与崩溃为外部来源（媒体/实测），非官方 release notes 内容——这正是"官方 N/A 不可信"的例证。
- 新增版本核对的流程：`node scripts/fetch-release-notes.mjs <版本>` → 与官方原文比对 → 追加一行记录。
