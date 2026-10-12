# Git 使用说明

项目目录：`D:\HowDoI`。
远程仓库：<https://github.com/K1TAproject/HowDoI>。
分支：`main`，远程名：`origin`。

## 日常提交与上传

在项目目录打开终端：

```powershell
git status
git add .
git diff --cached --stat
git commit -m "描述本次修改"
git push
```

`git commit` 保存本地版本；`git push` 上传已提交内容。仅编辑文件或执行 `git add` 不会上传。

首次远程推送设置跟踪分支后，当前电脑后续直接执行 `git push` 即可。若 GitHub 要求登录，按 Git Credential Manager 提示使用 GitHub 账号完成授权。提交姓名和邮箱不等于登录凭据，不要把密码或访问令牌写入项目。

## 从远程获取更新

工作区干净时执行：

```powershell
git pull --ff-only
```

若本地有未提交修改，先提交或暂存后再拉取。若提示分支分叉，先检查差异，不使用强制推送覆盖远程提交。

## 新电脑

```powershell
git clone https://github.com/K1TAproject/HowDoI.git
cd HowDoI
git config user.name "K1TAproject"
git config user.email "moxizhe68@gmail.com"
```

Git 的仓库配置存储在本机 `.git/config`，不会跟随普通项目文件上传。新电脑还需完成 GitHub 登录。

## 忽略规则

`.gitignore` 排除本地工具缓存、临时文件、应用本地数据库、构建产物和常见签名密钥；源码、设计文档及将来的 Flutter `pubspec.lock` 正常提交。

公共仓库中的已提交内容和提交邮箱可公开查看。上传前检查暂存内容，不提交真实账本、旅行预订凭证或密钥；忽略规则不能自动识别所有敏感内容。
