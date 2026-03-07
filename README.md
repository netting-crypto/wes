# USTC 综合科研仪器共享平台自动化

这个仓库现在按 Slurm 队列模式执行：

- 本机写代码并 `git push` 到 GitLab
- GitLab shell runner 只负责在登录节点提交 `sbatch`
- 真正的任务在 Slurm 计算节点里执行
- 任务结束后自动产出 Excel、`summary.json`、`summary.md`、`summary.html`
- 在 GitLab Job 的 `Artifacts` 里下载结果和 Slurm 日志

## 当前执行链路

1. 你在本地提交代码到 GitLab
2. GitLab 触发项目里的 `run_task`
3. Runner 在登录节点执行 `bash scripts/ci-submit-slurm.sh`
4. `ci-submit-slurm.sh` 提交 `scripts/slurm-job.sh` 到 Slurm
5. Slurm 作业在计算节点里执行 `npm ci`、`npx playwright install chromium`、`npm run pipeline`
6. 结果写回 `output/reports/`，GitLab 再把它作为 artifacts 保存

## Runner 在线方式

你现在的 runner 是 user-mode。它在线时需要在服务器上保持一个常驻进程：

```bash
cd ~/00soft/github_runner
nohup ./gitlab-runner run > runner.log 2>&1 &
```

检查是否在线：

```bash
./gitlab-runner verify
```

如果你只想前台观察日志，也可以直接运行：

```bash
./gitlab-runner run
```

## GitLab CI 需要的输入

### 1. 登录态

先在本机执行：

```powershell
npm.cmd run capture-auth
```

生成 `data/storage-state.json` 后，把文件全文保存到 GitLab CI/CD Variable：

- 变量名：`STORAGE_STATE_JSON`

流水线开始时会自动把它写回 `data/storage-state.json`。

### 2. Excel 模板

把模板 Excel 文件提交到仓库的 `templates/` 目录。

默认会从这里读取模板：

- [templates](C:/Users/witch/Documents/Playground/templates)

### 3. Slurm 参数

下面这些变量可以直接在 GitLab CI/CD Variables 里配置：

- `SLURM_PARTITION`：指定分区
- `SLURM_ACCOUNT`：指定账户
- `SLURM_QOS`：指定 qos
- `SLURM_TIME`：任务时限，默认 `02:00:00`
- `SLURM_CPUS_PER_TASK`：默认 `2`
- `SLURM_MEM`：默认 `4G`
- `SLURM_EXTRA_ARGS`：额外 `sbatch` 参数
- `SLURM_ENV_SETUP`：任务启动前执行的环境初始化命令

如果你的集群需要先加载模块或 conda，再跑 Node，可以把它写到 `SLURM_ENV_SETUP`，例如：

```bash
source ~/.bashrc && conda activate base
```

或者：

```bash
source /etc/profile && module load nodejs
```

### 4. 可选跳过项

如果服务器环境已经准备好依赖，可以设置：

- `SKIP_NPM_CI=1`
- `SKIP_PLAYWRIGHT_INSTALL=1`

## 本地使用

安装依赖：

```powershell
npm.cmd install
npx.cmd playwright install chromium
```

首次保存登录态：

```powershell
npm.cmd run capture-auth
```

执行主任务：

```powershell
npm.cmd run
```

只生成报告：

```powershell
npm.cmd run report
```

完整跑一遍任务并生成报告：

```powershell
npm.cmd run pipeline
```

## 输出结果

默认输出目录是 `output/reports/`，其中包含：

- `summary.json`：完整原始汇总数据
- `stats.json`：统计摘要
- `summary.md`：简版文字结果
- `summary.html`：可直接打开看的图表报告
- 多个 `.xlsx`：按记录导出的 Excel

Slurm 相关日志会写到：

- `output/slurm/`

## 已支持的环境变量

- `OUTPUT_DIR`：覆盖输出目录
- `TEMPLATE_DIR`：覆盖 Excel 模板目录
- `STORAGE_STATE_PATH`：覆盖登录态文件路径
- `HEADLESS`：默认 `1`，服务器上无头运行；设成 `0` 可显示浏览器
- `CHROME_PATH`：如果你要复用系统 Chrome，可指定浏览器路径
- `START_PAGE`：从第几页开始处理，默认 `1`
- `END_PAGE`：处理到第几页，默认 `0` 表示到最后一页

## 首次联调时你需要核对

因为页面结构仍然依赖真实站点，首次跑通后请重点核对 [config/selectors.json](C:/Users/witch/Documents/Playground/config/selectors.json)：

1. 列表页每行的“编辑”按钮选择器
2. 锁定状态字段对应的文本
3. 编辑页“测试内容”输入框选择器
4. 保存后两个弹窗的关闭方式