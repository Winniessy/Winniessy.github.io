# 一次 GitHub SSH 推送失败的完整排查记录

## 背景

在将一个本地项目开源到 GitHub 时，已经完成了以下准备工作：

- 创建 GitHub 公共仓库。
- 初始化本地 Git 仓库。
- 完成代码提交。
- 配置远程仓库地址。
- 生成专用 SSH 密钥。
- 将公钥添加为 GitHub Deploy Key。

看起来一切准备就绪，但执行 `git push` 时仍然连续失败。本次问题并非由单一原因导致，而是网络、SSH 配置、密钥口令和 Windows 文件权限等多个问题叠加造成的。

## 一、SSH 地址不等于 SSH 密钥

最开始使用的远程仓库地址类似于：

```text
git@github.com:username/repository.git
```

这个地址只负责告诉 Git 仓库在哪里，并不能证明当前电脑拥有推送权限。

SSH 推送还需要一对密钥：

- **私钥**：保存在本机，不能泄露或上传。
- **公钥**：添加到 GitHub 账号或仓库中。

GitHub 收到连接请求后，会检查本机提供的私钥是否与已保存的公钥匹配。只有验证通过，才能读取或写入仓库。

## 二、第一次失败：GitHub 网络连接异常

最初使用 HTTPS 推送时出现：

```text
Failed to connect to github.com port 443
```

这说明问题发生在网络层，还没有进入账号或仓库权限验证。

检查后发现，本机代理软件监听在本地端口，但 Git 并没有自动使用系统代理。因此浏览器能够访问 GitHub，不代表终端里的 Git 也能访问 GitHub。

可以为当前仓库单独设置代理：

```bash
git config http.proxy http://127.0.0.1:7890
git config https.proxy http://127.0.0.1:7890
```

为了避免影响其他项目，这里没有使用 `--global`。

不过，HTTPS 推送仍然需要额外的账号授权。为减少网页登录和凭据管理问题，后续重新采用 SSH 方案。

## 三、为仓库配置专用 Deploy Key

为该项目生成独立的 Ed25519 密钥，并将公钥添加到：

```text
Repository → Settings → Deploy keys
```

添加时需要勾选：

```text
Allow write access
```

GitHub 页面显示密钥状态为 `Read/write`，并且页面中的 SHA256 指纹与本地公钥完全一致，因此可以确认：

- 公钥已添加到正确仓库。
- 公钥内容没有复制错误。
- GitHub 已赋予该密钥写入权限。

使用独立 Deploy Key 的好处是权限范围仅限当前仓库。即使该密钥出现问题，也不会直接影响同一账号下的其他仓库。

## 四、第二次失败：不兼容的 SSH 配置参数

推送脚本中曾使用：

```text
ssh -F NUL
```

原本的目的是让 SSH 忽略用户级配置文件，但当前 Git/SSH 组合没有将 `NUL` 正确识别为 Windows 空设备，而是把它当成普通文件路径，最终报错：

```text
Can't open user config file NUL
```

解决方式是删除该参数，让 SSH 使用正常配置：

```bash
ssh -i "path/to/private_key" -o IdentitiesOnly=yes
```

## 五、第三次失败：Windows 私钥权限错误

随后出现：

```text
Load key "...": Permission denied
```

检查文件权限后发现，私钥由受控开发环境生成，文件所有者是沙箱账号，而不是当前登录 Windows 的用户。

因此出现了一个特殊情况：

- 私钥文件确实存在。
- Git 能找到对应路径。
- GitHub 上也存在匹配的公钥。
- 但本地 SSH 没有权限读取私钥。

为当前 Windows 用户授予私钥访问权限后，`Load key` 错误消失。

这个问题说明：SSH 密钥是否存在并不重要，真正重要的是执行 SSH 的用户能否读取私钥。

## 六、第四次失败：空口令被错误写成 `""`

生成密钥时，本来希望创建一把无口令密钥，但由于命令行引号处理错误，实际将两个双引号：

```text
""
```

设置成了私钥口令。

所以运行 SSH 测试时反复出现：

```text
Enter passphrase for key ...
```

直接按回车相当于输入空口令，自然无法解锁这把私钥。

通过以下命令修改私钥口令：

```bash
ssh-keygen -p -f "path/to/private_key"
```

操作过程如下：

1. 旧口令输入两个双引号 `""`。
2. 新口令直接按回车。
3. 再次确认新口令时直接按回车。

这样可以在不改变公钥的前提下移除私钥口令，因此不需要重新配置 GitHub Deploy Key。

## 七、第五次失败：私钥只有读取权限

修改口令时又出现：

```text
Saving key failed: Permission denied
```

这说明 SSH 已经能够读取私钥，但当前 Windows 用户只有只读权限，无法保存修改后的文件。

为当前用户临时授予完整权限：

```powershell
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls "path/to/private_key" /grant:r "${me}:(F)"
```

然后重新执行 `ssh-keygen -p`，成功清除口令。

## 八、验证 SSH 连接

在执行正式推送前，先单独测试 SSH：

```bash
ssh -T -i "path/to/private_key" -o IdentitiesOnly=yes git@github.com
```

成功时会显示类似信息：

```text
Hi username/repository! You've successfully authenticated, but GitHub does not provide shell access.
```

这句话表示：

- 网络连接正常。
- 私钥能够读取。
- 密钥验证成功。
- GitHub 已经识别当前身份。

GitHub 不提供普通 SSH Shell，因此“不提供 shell access”属于正常提示，不是错误。

## 九、完成推送

SSH 验证通过后，设置远程仓库地址：

```bash
git remote set-url origin git@github.com:username/repository.git
```

指定当前项目使用的私钥：

```powershell
$env:GIT_SSH_COMMAND = 'ssh -i "path/to/private_key" -o IdentitiesOnly=yes'
```

最后执行推送：

```bash
git push -u origin main
```

其中：

- `origin` 是远程仓库名称。
- `main` 是本地分支名称。
- `-u` 会建立本地分支与远程分支的跟踪关系。

完成首次推送后，后续通常只需执行：

```bash
git push
```

## 十、问题总结

| 阶段 | 错误表现 | 实际原因 | 解决方案 |
| --- | --- | --- | --- |
| HTTPS 连接 | 无法连接 443 端口 | Git 未使用本地代理 | 为当前仓库设置代理 |
| SSH 初始认证 | `Permission denied (publickey)` | 缺少可用 SSH 身份 | 生成密钥并添加 Deploy Key |
| SSH 配置 | 无法打开 `NUL` | SSH 参数不兼容 | 删除 `-F NUL` |
| 私钥加载 | `Load key: Permission denied` | Windows 用户无权读取私钥 | 修复私钥 ACL |
| SSH 解锁 | 反复要求 passphrase | `""` 被错误设置成口令 | 使用 `ssh-keygen -p` 清除口令 |
| 私钥保存 | `Saving key failed` | 用户只有读取权限 | 临时授予文件写入权限 |
| 最终推送 | 推送成功 | 网络、密钥和权限全部正确 | 建立远程跟踪分支 |

## 十一、经验与改进

1. **SSH 仓库地址不等于 SSH 身份。** 地址负责定位仓库，密钥负责证明权限。
2. **浏览器能访问 GitHub，不代表 Git 能访问。** 浏览器和终端可能使用不同的代理设置。
3. **看到 `Permission denied` 时要区分发生位置。** `Load key` 通常是本地文件权限问题；`publickey` 通常是 SSH 身份验证问题。
4. **添加 Deploy Key 后应核对指纹。** 本地和 GitHub 显示的 SHA256 指纹一致，才能确认公钥没有复制错误。
5. **在正式推送前先运行 `ssh -T`。** 这样可以把 SSH 认证问题与 Git 分支、远程仓库问题分开排查。
6. **Windows 上需要特别关注私钥 ACL。** 私钥路径正确但用户无权读取或写入时，SSH 仍然无法工作。
7. **自动生成密钥时必须验证口令参数。** 命令行中的空字符串和字面量 `""` 并不是一回事。

## 最终结论

这次问题并不是“本地没有安装 Git”，也不是“GitHub 没有添加 Deploy Key”。

真正的核心问题是：

> GitHub 上的公钥配置正确，但本地 SSH 一开始无法正确读取、解锁并使用与之对应的私钥。

通过依次检查网络、仓库地址、公钥指纹、私钥口令和 Windows 文件权限，最终完成了 SSH 身份验证和代码推送。
