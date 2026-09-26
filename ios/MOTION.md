# 原生动画交接

Figma 图库 motion context 返回空 keyframe inventory。以下实现遵循用户批准的原生动画合同，不声称是自动导出的 Figma Smart Animate。

对应 Apple 原生接口：[ZoomNavigationTransition](https://developer.apple.com/documentation/swiftui/zoomnavigationtransition)、[accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)。最低版本可用性同时由 iOS 18 部署目标编译检查。

| 交互 | 实现与取消行为 | Reduce Motion |
| --- | --- | --- |
| 图库/回忆 → 详情 | 稳定档案 ID 的 matchedTransitionSource + 系统 zoom；真实 NavigationStack 返回，来源 ScrollView 保持实例 | 不添加 zoom 修饰器，使用系统导航降级 |
| 详情左右浏览 | 系统 page TabView，当前媒体驱动日期、信息、分享与故事入口 | 系统接管 |
| 信息面板 | 系统 sheet，中/大档位，拖动可关闭；编辑是独立草稿 sheet | 系统接管 |
| 未保存编辑 | 关闭手势禁用，取消按钮明确询问放弃；保存期间禁止重复提交 | 无自定义位移 |
| 多选 | 仅勾选图标轻量 spring（response .28 / damping .88），不对网格施加 spring | 取消自定义 animation |
| 故事排序 | Form 的系统 onMove 手柄，另有前移/后移操作；排序只影响草稿，取消还原 | 系统接管 |
| 日期/媒体过滤 | 短暂 .18 秒 easeOut；不添加照片飞入效果 | 直接切换 |
| 保存 | 禁止重复点击，按钮“保存中”；失败保留草稿可重试 | 文本反馈 |
| 演示同步 | 明确“演示”状态，失败/重试共享同一 store，不冻结其他标签 | 不自定义循环动画 |

需后续在真实照片库和真机补测大图库、低内存、PhotoKit 变更、原图下载、交互返回中断及 iOS 18 运行时。模拟器的录屏不能证明真机帧率。
