# USTC 综合科研仪器共享平台自动化

这个仓库现在已经补齐了适合 GitLab 的自动化链路基础：

- 本机写代码并 `git push` 到 GitLab
- GitLab Pipeline 在你的服务器 Runner 上自动执行任务
- 任务结束后自动产出 Excel、`summary.json`、`summary.md`、`summary.html`
- 在 GitLab Job 的 `Artifacts` 里直接下载初步结果报告

## 你要完成的基础连接

### 1. 这台电脑连上 GitLab

先在这台 Windows 机器上配置 Git 用户和 SSH Key：

```powershell
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
ssh-keygen -t ed25519 -C "你的邮箱"
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

把公钥加到 GitLab 的 `Preferences -> SSH Keys`，然后把仓库远端地址配上：

```powershell
git remote add origin git@gitlab.example.com:group/project.git
ssh -T git@gitlab.example.com
git push -u origin main
```

### 2. 你的服务器接 GitLab Runner

推荐在你的服务器上安装 `gitlab-runner`，并注册成 `shell runner`，标签要和仓库里的 `.gitlab-ci.yml` 一致，也就是 `task-runner`。

Runner 需要满足：

- 已安装 Node.js
- 能执行 `npm ci`
- 能运行 Playwright Chromium
- 能访问目标业务网站

### 3. 给 Pipeline 提供登录态和模板

这个项目跑自动任务需要两类外部文件：

- 登录态：`storage-state.json`
- Excel 模板：放在 `templates/` 目录下

推荐做法：

1. 先在本机执行 `npm.cmd run capture-auth` 获取 `data/storage-state.json`
2. 打开这个 JSON 文件，把完整内容存进 GitLab CI/CD Variable `STORAGE_STATE_JSON`
3. 把 Excel 模板文件提交到仓库的 `templates/` 目录，或者在 GitLab 变量里覆盖 `TEMPLATE_DIR`

`.gitlab-ci.yml` 已经支持在流水线开始时把 `STORAGE_STATE_JSON` 写回 `data/storage-state.json`。

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

默认输出目录改成了仓库内的 `output/reports/`，其中包含：

- `summary.json`：完整原始汇总数据
- `stats.json`：统计摘要
- `summary.md`：简版文字结果
- `summary.html`：可直接打开看的图表报告
- 多个 `.xlsx`：按记录导出的 Excel

## 已支持的环境变量

- `OUTPUT_DIR`：覆盖输出目录
- `TEMPLATE_DIR`：覆盖 Excel 模板目录
- `STORAGE_STATE_PATH`：覆盖登录态文件路径
- `HEADLESS`：默认 `1`，服务器上无头运行；设成 `0` 可显示浏览器
- `CHROME_PATH`：如果你要复用系统 Chrome，可指定浏览器路径

## 首次联调时你需要核对

因为页面结构仍然依赖真实站点，首次跑通后请重点核对 [config/selectors.json](C:/Users/witch/Documents/Playground/config/selectors.json)：

1. 列表页每行的“编辑”按钮选择器
2. 锁定状态字段对应的文本
3. 编辑页“测试内容”输入框选择器
4. 保存后两个弹窗的关闭方式
