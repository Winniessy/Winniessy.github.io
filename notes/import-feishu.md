# 从飞书导入学习记录

这个站点可以用 `scripts/import-note.ps1` 快速导入笔记。

## 从剪贴板导入

1. 在飞书里复制一篇笔记正文。
2. 回到 `my-site` 目录。
3. 运行：

```powershell
.\scripts\import-note.ps1 -Section linux -Title "Linux 文件权限学习" -Tags Linux,Shell
```

脚本会自动：

- 在对应栏目里创建 `.md` 文件。
- 把链接加到 `_sidebar.md`。
- 把链接加到首页 `README.md` 的“最新收录”。

## 从已有 Markdown 文件导入

```powershell
.\scripts\import-note.ps1 -Section mcu -Title "GPIO 输入输出" -Slug gpio-basic -Source "E:\tmp\gpio.md" -Tags MCU,GPIO
```

## Section 可选值

- `linux`
- `mcu`
- `projects`
- `notes`

## 推送

导入后检查：

```powershell
git status
```

提交并推送：

```powershell
git add README.md _sidebar.md linux mcu projects notes scripts
git commit -m "Add learning note"
git push
```
## 备注
可以，直接复制粘贴当然行，但我已经给你做了一个更省事的导入器。

现在新增了：

```text
scripts/import-note.ps1
notes/import-feishu.md
```

并且首页 `README.md` 里加了“最新收录”自动区，`_sidebar.md` 里也加了导入说明入口。已推送：

```text
2b42ed5 Add note import helper
```

以后从飞书导入一篇笔记的流程是：

1. 在飞书里复制笔记正文
2. 回到 VS Code 终端，进入 `my-site`
3. 运行，例如导入到 Linux 板块：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-note.ps1 -Section linux -Title "Linux 文件权限学习" -Tags Linux,Shell
```

它会自动：

- 创建一篇 `.md`
- 加到 `_sidebar.md`
- 加到首页 `README.md` 的“最新收录”

然后你只需要提交推送：

```powershell
git add README.md _sidebar.md linux notes scripts
git commit -m "Add learning note"
git push
```

如果标题是中文，脚本会自动生成时间戳文件名；如果你想文件名好看一点，可以加 `-Slug`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\import-note.ps1 -Section mcu -Title "GPIO 输入输出" -Slug gpio-basic -Tags MCU,GPIO
```