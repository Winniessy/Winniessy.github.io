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