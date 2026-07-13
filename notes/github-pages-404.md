# GitHub Pages 404 排查

日期：2026-07-13  
标签：GitHub Pages / DNS / SSH / 账号状态

## 问题

本地在 VS Code 里可以看到页面，但是浏览器访问 GitHub Pages 地址一直显示 404。

## 排查过程

1. 确认本地 `index.html` 可以正常打开。
2. 确认 DNS 已经解析到 GitHub Pages 的 IP。
3. 确认代码已经推送到远端仓库。
4. 检查 GitHub 账号状态，发现账号被 flagged。
5. 尝试使用新账号重新发布。

## 结论

本地页面正常，不代表线上已经发布成功。线上 404 可能来自 GitHub Pages 设置、仓库可见性、账号限制或部署流程没有完成。

## 经验

- 先区分“本地预览”和“线上访问”。
- 纯静态页面可以不使用 GitHub Actions。
- 如果账号被限制，需要先处理账号安全和 Support 问题。
