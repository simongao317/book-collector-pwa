# BookCollector PWA

这是图书收藏管理应用的 PWA 网页版。它保留 iOS 版的主要逻辑：

- 本地保存图书数据
- ISBN、统一书号、自定义书号不可重复
- 手写录入、CSV 导入、CSV 导出
- 摄像头扫码后用豆瓣图书查询 ISBN
- 已买：已读、未读
- 未买：已读、想读、待定
- 待定 30 天后自动删除
- 主界面筛选、搜索、直接修改状态

## 为什么推荐 Vercel

豆瓣图书页面通常不能被纯前端网页稳定跨域读取。这个项目包含 `api/douban.js`，用 Vercel 免费 Serverless Function 做查询代理，所以推荐部署到 Vercel。

GitHub Pages 只能托管静态文件，不能运行 `api/douban.js`，扫码后豆瓣自动查询会失效。

## 本地预览

如果只看界面，可以在这个目录启动任意静态服务器。但豆瓣查询接口需要 Vercel 环境。

推荐：

```bash
npm install
npm run dev
```

然后打开命令行显示的本地地址。

## 部署到 Vercel

1. 把 `pwa-book-collector` 文件夹上传到 GitHub 仓库。
2. 打开 https://vercel.com/ 并用 GitHub 登录。
3. 选择 `Add New...` -> `Project`。
4. 选择这个仓库。
5. 如果仓库根目录不是本文件夹，在 Vercel 的 `Root Directory` 里选择 `pwa-book-collector`。
6. 直接 Deploy。

部署完成后，用手机 Safari 或 Chrome 打开 Vercel 给你的网址，就可以添加到主屏幕。

## 手机添加到主屏幕

iPhone Safari：

1. 打开部署好的网址。
2. 点分享按钮。
3. 选择“添加到主屏幕”。

Android Chrome：

1. 打开部署好的网址。
2. 菜单里选择“安装应用”或“添加到主屏幕”。

## 摄像头扫码说明

扫码依赖浏览器的 `BarcodeDetector` 和摄像头权限。若当前浏览器不支持，会显示手动输入 ISBN 的输入框。
