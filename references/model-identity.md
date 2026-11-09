# 模型身份、成本档与授权边界

`SKILL.md`「执行配置与模型授权」只保留五条铁律级纪律；本文是它们的完整判据。

**何时读**：登记或修改 profile、标定模型身份、撞上 `MODEL_MISMATCH` 或 `Unknown profile
fields`、用户问"到底用的是不是这个模型"，或准备改项目配置（`project diff`）时。
只在日常派发时不需要读——那五条纪律已经够用。

主线只有一句：**模型身份分三层，不要越层表述**。下面的条目都服务于它。

## 1 基本纪律

- 不凭 profile 名或模型名推断能力与成本（`flash` / `pro` / `mini` 都不是证据）。
- 不自动推断价格：用户通过 `rules[].prefer` 明确表达顺序，或用 `cost_ceiling` 直接排除。
- 工具支持或新出现的模型不自动获得授权。**不得**自行修改 `agent_profiles` / `routing` 后
  `register`，把自己的选择变成"用户授权"；授权变更只能由人发起。
- 白名单没变但 profile 内容变了（换 `model` / `provider` / `endpoint_ref` /
  `permission_profile`），等于**授权对象变了**：在途任务走 `POLICY_CHANGED` + `rebind`，
  不能当成"还是原来那个 profile"。
- 模型不可用或任务失败时**不得静默切换**：固定模式暂停，自动模式也不在 `start` 阶段重选；
  换配置只能 `task reassign`（要求 stop-confirmed）。
- `allow_cli_default_model: true` 一律视为"运行模型未解析"，报告写"未解析"；工具事后报告了
  模型也不能倒推为启动前已固定。
- **模型身份分三层，不要越层表述**：① `model_unresolved=false` 只说"配置指定了模型"；
  ② `run.model_identity` 是"CLI 自报"这一层的结论——`reported_match` 表示逐字一致，
  `alias_confirmed` 表示上报值落在 profile 声明的 `model_aliases` 里（按声明等价，**不是**
  逐字一致），两者用 `identity_basis`（`exact` / `declared_alias`）区分；③ "服务端实际用了
  该模型"当前**没有证据源**。`combination_verified` 属 ②+usage 的集成标签，不是 ③。

## 2 别名与成本档

- **请求名与供应商名不同时，必须声明 `model_aliases`**：实测 codebuddy 2.111.0 用
  `--model BC-DeepSeek-V4-Flash` 请求，流里上报 `deepseek-v4.1-flash`，并由 `system/init`
  回显请求名（`custom-local:BC-DeepSeek-V4-Flash`）。runtime 只把回显记为 `request_echo`、
  不参与判定；其余上报值必须由 `model_aliases` 说明"它们是同一个模型"，否则结论是
  `reported_mismatch`（或两个不同名字时的 `mixed`）。声明前先实测一次，不要凭名字像就填。
  `model_aliases` 需要 runtime ≥ 1.5.1；更早版本会以 `Unknown profile fields` 拒绝，
  遇到时先升级而不是删掉别名后硬跑。
- **`cost_class` 按真实费用档登记**（`premium` 就写 `premium`）。`premium` 默认
  `pin_model=true`，这是要求而不是障碍：pin 接受 `reported_match`（逐字一致）与
  `alias_confirmed`（上报值落在 `model_aliases` 内）。**不得**用降档（把 `premium` 登记成
  `standard`）来"关掉"身份要求——那改的是用户声明的真实成本，后续任务会在错误的成本假设下
  派发。历史背景：早期 runtime 不读 `providerData.model`、也没有别名机制，`cb-pro` 曾因此
  登记为 `standard`；现在修好了，恢复 `premium` 需要人重新 `attest`，不要自行改授权。

## 3 探测、标定与不匹配

- **探测是真实模型调用**：`purpose: "probe"` 只影响质量归因（记为 `excluded`），**不改变
  执行链**——它计费、受 `cost_ceiling` / `spend_guard` 约束、过模型身份闸门、占用尝试次数
  与并发槽。用户不愿调用某个贵模型时，**不得**以"只是探测"为由替他发起；探测前同样要按
  上面的确认流程拿到授权。
- **标定顺序**：`task create` 带 `"purpose": "probe"`（结果不进质量统计）→ `start` → 读
  `task report TASK` 的 `requested_model` / `reported_model` / `reported_models[]` /
  `model_identity` / `identity_basis`。`scope=request_echo` 是请求名回显，**不参与判定**。
- **撞上 `MODEL_MISMATCH` 不是死路**：被拒时 `block_details` 已带 `reported` /
  `reported_models` / `request_echoes` / `declared_aliases`（`task status --json` 返回完整
  任务记录），标定证据照样拿得到；工作区会被隔离成 patch（不丢失但停住），对 probe 任务
  影响可忽略。
- **登记别名要有依据，不是看到差异就补**：

  | 观测（`model_identity`） | 允许的动作 |
  |---|---|
  | `reported_match` | 无需别名，可直接 `premium` |
  | `reported_mismatch` | **默认保持不匹配**。只有上报名的作用域清楚（是同一 provider 的别名而不是另一个模型）、命名关系有可信依据、且用户确认后，才登记 `model_aliases` |
  | `mixed`（一次运行多个不同名） | **不得整组写入别名**；先查清为什么一次运行出现多个模型标识 |
  | `unobserved` | 查适配器输出协议；pin 无法满足，需与用户决定是显式声明、换候选还是换适配器 |

  别名或模型变更都会改变配置摘要：`register` → 重新 `attest` → 用新的 probe 复验。汇报措辞
  固定为**"按声明等价"**（`identity_basis=declared_alias`），**不得**写成"已证明使用该模型"。

## 4 诊断与改配置

- 确定性检查（lint / 类型 / 测试）由 Runtime 执行，与模型选择无关。
- 配置有问题时 `status` / `doctor` 仍应能读出记录：`doctor` 的 `policy_problems[]` 与
  `placeholders_ok` 要原样转述，不要用"环境问题"概括。
- **改任何项目配置之前先跑 `project diff`**：`max_active_tasks` / `timeout_seconds` /
  `max_attempts` / `checks` 都会进入 `policy_digest`，改完所有在途任务 `POLICY_CHANGED`
  （包括已 `REVIEW_READY`、只差 `accept` 的）。动作固定为：

  ```bash
  bash <skill-dir>/scripts/zoe.sh project diff --config <new-config.json> --json
  ```

  把 `changed_fields` / `affected_tasks[]` / `suggested_commands[]` **原样**列给用户，并说明
  "已可评审的任务会失效，需要逐个 `rebind`"。这属于**用户改变项目政策**，要人批；
  不得用"只是调个并发"概括，也不得自己把 `rebind` 批量跑完再汇报。
  并发与超时的调整尽量安排在波次边界（没有 `REVIEW_READY` 在等验收时）。
