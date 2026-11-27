【Root模块分享】App Download Binder v3.2.1｜把微信/QQ/企微/TG下载目录统一归类

先叠个甲：本人纯小白，这个模块完全是和 AI（Antigravity）一点点磨出来的，肯定还有不完善的地方，各位大佬发现 Bug 或有更好的写法欢迎直接在评论区指出！🙏

安卓 11+ 自带文件管理器打不开 Android/data，找个下载的文件太费劲，所以做了个纯本地 Root 模块，把各软件的下载目录统一映射到：
📂 /sdcard/Download/应用下载/<软件名>/

✨ 主要特点
• 不占双倍空间 & 不重复相册：底层 mount --bind 实时映射，自动置入 .nomedia 防止系统相册出现两张一样的照片/视频
• 一软件一中文文件夹：自动合并同软件多路径，不出现 com.xxx.xxx 英文包名
• 不带垃圾缓存：排除 cache/日志/缩略图，Telegram 只映射下载文件
• 纯本地零联网：内置 235 条开源规则库 + 每天自动检测新 App
• 兼容 KernelSU / APatch / Magisk：开机解锁后自动生效
• 刷入音量键自选：先确认风险，再自选全自动扫描 / 标准规则库
• 干净无残留：覆盖更新与卸载自动解除挂载并清理映射目录，不删原文件

🛠️ 用法
刷入重启、解锁进桌面等 3 秒即可在文件管理器看到。想手动加 App 可以编辑模块目录里的 rules.conf，再点模块里的「一键扫描并重载挂载.sh」或模块页「操作」立即生效。
（Chrome 直接下在 Download 根目录，建议配合 Storage Redirect X 映射到 Download/应用下载/Chrome）

⚠️ 提醒：映射目录与原目录是同一份文件，删除会同步生效，操作前请确认！

👤 作者：KrisWu & Antigravity（纯 AI 辅助制作）
🙏 规则库引用：Kindness-Net/storage-redirection-x-rules（上游 RikkaApps/StorageRedirect-assets）；参考 Storage Redirect X 与 Third_Party_Redirect

📦 GitHub 开源与下载：
https://github.com/beichen123-hub/app-download-binder/releases/latest

再次叠甲，小白折腾不易，有不对的地方请各位酷友在评论区轻喷并指出，我会让 AI 一起改！
