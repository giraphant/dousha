# Doubao IME 协议逆向 — 调研笔记

这份文档记录从 Doubao IME 安卓 APK 反编译里挖出来的协议细节，以及对应到 dousha Swift 实现里的差距和修补。意图不是写完整的协议规范，而是给未来继续挖 SAMICore native lib 行为提供起点 — 哪里已经看过、哪里还没看、哪些是关键的 grep 锚点。

## 1. APK 反编译环境

```bash
# 工具
brew install jadx          # Java 反编译 + GUI

# 反编译（产物 ~77MB / ~10k Java 文件）
jadx -d DoubaoIME-decompiled --no-res --show-bad-code DoubaoIME.apk
```

`DoubaoIME.apk` 和 `DoubaoIME-decompiled/` 都已经在 `.gitignore` 里。每次更新 APK 后重新跑反编译命令即可。

## 2. 整体架构

Doubao 安卓客户端**不直接发 WebSocket 协议**，而是通过 native lib `SAMICore` (`com.mammon.audiosdk.SAMICore`) 转一道。Java 层只是配置 + 喂音频 + 收回调；真正的 WS 帧编码、frame_state 处理、重试、音频缓存全在 `.so` 里。

这意味着：
- **Java 反编译能看到**：StartSession 的 JSON 配置、SAMICore 暴露的 enum 和 struct、ping interval 等 metadata
- **Java 反编译看不到**：FrameState 枚举的实际值、WS 帧的二进制布局、SAMICore 内部的重试/缓存逻辑

如果以后要挖 native 行为，得动 frida 或读 `.so` 反汇编 — 这条路目前没走，因为 Java 层信息已经够撬出主要修复。

### 关键文件地图

| 文件 | 内容 |
|---|---|
| `com/bytedance/android/input/common/asr/sdkImp/SdkImpl.java` | 1342 行主实现，包含 StartSession 的全部 JSON 字段、SAMICoreAsrContextCreateParameter 的全部 native 字段、feedAudio 的 extra JSON 构造 |
| `com/bytedance/android/input/common/t/a/d/a.java` | WS connect pool 配置，含 `UpdateFrontierClientPingInterval(3000)` |
| `com/mammon/audiosdk/SAMICore.java` | SAMICore 的 JNI 入口，看得到方法签名但不到实现 |
| `com/mammon/audiosdk/enums/SAMICoreContextType.java` | enum 列出 14 个 context type，FrontierClient 相关有 12/13/14、Cell 系列 112/113/114 |
| `com/mammon/audiosdk/structures/SAMICoreAudioBin.java` | 音频块结构（只有一个 `byte[] audioData` 字段） |

### 有效的 grep 锚点

跟服务器协议相关的字符串在 Java 层是明文的（不被混淆），可以用来反向定位代码：

- `enable_asr_threepass` / `enable_asr_twopass` → StartSession config builder
- `frontier-audio-ime-ws.doubao.com` → WS URL 配置点
- `x-custom-keepalive` → 不在 APK 里（这是 Python reference 加的，不是官方）
- `frame_state` / `FrameState` → 不在 Java 里（在 native 内部）
- `finish_audio` / `force_asr_twopass` → SAMICoreBlock.extra 的 per-frame JSON

## 3. dousha 已经吸收的修复

按重要性排序，每条都标了来源行号。

### 3.1 [关键] interim segment rescue（无对应官方代码 — 我们的发明）

**根本问题**：Doubao 服务器**整个 session 期间从不发 `is_vad_finished=true`**，只在 `FinishSession` 之后的最终响应里发一次。意思是：

- 长录音里服务器会把音频切成多个 utterance（每次新 utterance 开始时 `text` 字段会从短小重新累积）
- 但每个 utterance 的"完成"信号从不到达
- dousha 之前的 `handleResponseData` 只在收到 `vad_finished=true` 时 commit segment，于是**每段长录音只能保住最后一个 utterance**

**修法**：在 `handleResponseData` 里检测"文本急剧缩水"（`newText.count * 2 < currentInterim.count` 且不是前缀关系），把上一段 interim 当作 rescued segment commit 掉。这是经验性的，没有官方代码对照，但实测能从单 segment 抢救到 4+ segment。

**Java 证据**：完全没有 — 官方客户端走 SAMICore native 路径，segment 边界处理在 `.so` 里。我们看到 Java 层只是 `SAMICoreProcess(block, null)` 然后等回调，所以官方怎么处理这个问题我们不知道。可能 SAMICore 内部用了类似 rescue 的启发式，也可能服务器在 SAMICore 的连接模式下行为不同。**待验证**。

### 3.2 [关键] WebSocket 3 秒 PING

**官方代码**：
```java
// com/bytedance/android/input/common/t/a/d/a.java:113
SAMICore.UpdateFrontierClientPingInterval(3000);
```

**dousha 之前**：完全没有 ping 机制（虽然请求头里有个 `x-custom-keepalive: true`，但那是 Python reference 加的、跟实际行为无关）。

**修法**：`DoubaoASR.swift` 里加 `pingTask`，每 3 秒调一次 `ws.sendPing { ... }`，跟 WS 生命周期绑定（open 时启动、close/recv-fail 时停）。

**注意**：这个 `UpdateFrontierClientPingInterval` 实际只在 `isCanWsOpt() == false` 的分支被调到（QUIC + WS 混合模式）。在纯 WS 模式（`isCanWsOpt == true`，dousha 用的就是这条路径）下，Java 层看不到 ping 配置 — 可能由 SAMICore 的 pool client 内部默认设置。但加上 3 秒 ping 实测没有副作用、且对长录音稳定性有帮助。

### 3.3 [关键] `finish_audio: true` 标记最后一帧

**官方代码**：
```java
// SdkImpl.java:1232-1240
JSONObject jSONObject = new JSONObject();
if (z) jSONObject.put("force_asr_twopass", true);
if (z2) jSONObject.put("finish_audio", true);
sAMICoreBlock.extra = jSONObject.toString();
```

官方客户端通过 SAMICoreBlock 的 `extra` JSON 标记最后一帧，**不只是靠 protobuf 的 frame_state=LAST**。

**修法**：`AsrProtocol.swift` 里 `taskRequest` 在 `frameState == .last` 时把 payload 改成 `"extra":{"finish_audio":true}`。

### 3.4 [次要] StartSession config 补全

**官方代码**：`SdkImpl.java:660-734` 里 build 出的 `jSONObject2`（extra 字段）有 20+ 个 key，dousha 之前只发了其中 6 个。补上后效果最明显的两个：

```java
// SdkImpl.java:685
jSONObject2.put("end_smooth_window_ms", aVar.u().getInt("vad_setting_ms", 800));
// SdkImpl.java:689
jSONObject2.put("use_twopass_retry", true);
```

`end_smooth_window_ms = 800` 是服务器端 VAD 收尾窗口；不设的话用服务器默认值（似乎更激进，会截尾巴）。

**官方还设了但 dousha 没补的**（懒得加，不一定影响掐流）：
- `network_change.{switch_network_quality_threshold, switch_network_rtt_threshold, switch_network_ping_timeout}` — 多链路切换阈值，dousha 没多链路所以无关
- `retry_server_code` — 客户端遇到这些 server code 时重连
- `disable_user_words`、`strong_ddc` — 行为微调
- `device_brand/model`、`app_version`、`os_version`、`os_type` — 设备指纹（让请求"看起来像官方客户端"，可能减少被服务器降级的概率，未验证）

### 3.5 [次要] finish-wait 4s → 10s

**官方代码**：
```java
// SdkImpl.java:757
sAMICoreAsrContextCreateParameter.finish_wait_timeout = 10000;
```

dousha 主 session 和 retranscribe 路径都跟着改成 10s。之前 4s 在长录音里会切断服务器尚未处理完的尾巴。

### 3.6 [次要] retranscribe 比原文短就保留原文

跟协议无关，纯客户端逻辑。`AppDelegate.swift` 之前 retranscribe 一返回非空就覆盖原文 — 即使 retranscribe 自己被掐了。新逻辑：retranscribe 必须严格更长才采用。

### 3.7 [可选] incomplete-detector segment-gap 阈值

加 rescue 后，rescue 出来的 segment 之间正常 gap 可达 20+ 秒（用户连续说话期间的 utterance 切分点），原 10s 阈值频繁误报、触发不必要的 retranscribe。已调到 25s。这个属于"治标"调整，根本上 `maxSegmentGap` 信号在有 rescue 的情况下意义已经变了 — 它现在测的是"两次 rescue/finalize 之间多远"，跟"音频丢了多少"关联度不高。

## 4. 已知但**尚未挖透**的方向

如果未来要进一步对齐官方行为，按 ROI 排序：

### A. SAMICore 的客户端重试（高价值，高成本）

```java
// SdkImpl.java:751-756
sAMICoreAsrContextCreateParameter.enable_audio_cache = 1;
sAMICoreAsrContextCreateParameter.audio_cache_size = 320000;
sAMICoreAsrContextCreateParameter.retry_mode = 1;
sAMICoreAsrContextCreateParameter.retry_count = 7;
sAMICoreAsrContextCreateParameter.max_retry_time_ms = 9500;
sAMICoreAsrContextCreateParameter.retry_interval_time_ms = new int[]{200, 400, 800, 1000};
```

官方有 7 次重试 + 320KB 音频缓存 + 指数退避，全部在 SAMICore 内部实现。dousha 用 retranscribe + WAV side-recording 变相覆盖了"重试"语义，但不是细粒度的（一次性重试整段，不是断点续传）。

**可能的进展方向**：
- 在 WS 断开时尝试重连并续传剩余音频
- 把"断点位置"和"已 commit 文本"挂钩，避免重新发送已确认部分

### B. 多链路 QUIC + WS 混合（高价值，极高成本）

```java
// SdkImpl.java:762
sAMICoreAsrContextCreateParameter.enable_multi_connection = z2;
```

官方在 `isCanWsOpt() == false` 时同时开 QUIC（`frontier-audio-ime-quic.doubao.com`）和 WS，由 SAMICore 自动选优 / 切换。dousha 只走纯 WS。在网络抖动时官方的多链路应该更稳。

这条几乎不可能在 Swift 端复现，除非用 NWConnection 写底层 QUIC，工作量极大。

### C. `frame_time_ms = 10`（中价值，中成本）

```java
// SdkImpl.java:763
sAMICoreAsrContextCreateParameter.frame_time_ms = 10;
```

官方用 10ms 帧，dousha 用 20ms（`DoubaoConstants.frameDurationMs`）。Opus 编码器配置也要跟着改。不一定影响掐流，但可能影响服务器侧 VAD 节奏。值得试，不算紧急。

### D. FrameState 枚举完整值

```swift
// AsrProtocol.swift
case unspecified = 0
case first = 1
// 2 缺失
case middle = 3
// 4, 5, 6, 7, 8 都缺失
case last = 9
```

值 2、4-8 在 Java 层没出现（不在 SAMICore 暴露的接口里）。要拿到完整定义需要：
- 反编译 SAMICore 的 `.so`（IDA / Ghidra）
- 或者抓 mitmproxy 流量看真实帧
- 或者在 `frida` hook SAMICore 调用看 native 入口的参数

dousha 现在用 1/3/9 跑得通，但可能缺了某些场景下的合适 frame_state（比如"keep alive"或"silence"专用值）。**待挖**。

### E. SAMICoreBlock 的 extra JSON 还能塞什么

只看到两个 key 被用：
- `finish_audio: true` — 最后一帧（已采纳）
- `force_asr_twopass: true` — 触发条件未知，可能跟某种手动 "现在请重新跑一遍 twopass" 有关

如果未来加 SDK 控制逻辑（比如用户手动触发重新转写），这个值得验证。

### F. 服务器端 retry_server_code 列表

```java
// SdkImpl.java:712
jSONObject2.put("retry_server_code", jSONArray);
```

`jSONArray` 来自 `IInputSettings.a.d().o()` — 一个 server 端配置的整数列表。看 settings 是 Bytedance 的远程配置系统，本地拉不到。但**如果能知道具体哪些 code 触发重试**，dousha 也可以加同样的客户端重连逻辑。

走 mitmproxy 抓一次官方 settings 拉取的响应应该能拿到这个列表。

## 5. 调试技巧

### 5.1 看哪个 segment 是从哪儿来的

`DoubaoASR.swift` 的 `handleResponseData` 里有两类 segment commit 日志：

- `[DoubaoASR] segment final='...' totalSegments=N` — 服务器 vad_finished 触发的正常 commit
- `[DoubaoASR] segment final (rescued from interim, newText.len=N)='...' totalSegments=N` — 我们的 rescue 触发的 commit

如果一段录音里有大量 `(rescued)` segment，说明服务器在频繁切 utterance 但从不 finalize（这是 Doubao 标准行为）。如果一段录音 `totalSegments=1` 且时间很长，说明 rescue 没触发 — 要么文本一直在长（没出现戏剧性 drop），要么阈值太严。

### 5.2 看每个 recv 的 flag

`handleResponseData` 里 `[DoubaoASR] result isInterim=... vadFinished=... nonstream=... textLen=... preview=...` 是 per-recv 日志。

用法：录一段刻意场景（中段长停顿、夹杂英文等），然后看 Console.app 或 `log show`：

```bash
/usr/bin/log show --predicate 'subsystem == "com.dousha.app"' --info --last 5m \
  | grep -E "result isInterim|segment final|stop\(\) final"
```

每条 recv 的 textLen 变化是判断 segment 切换的最直接信号。

### 5.3 看是否在掉流

`receive failed: Socket is not connected` 在 stop()/cancel() 之后出现是正常（关闭握手的副产物）；如果在录音中段出现就是真掐流。

`ws ping failed: ...` 在 stop() 后两条左右是正常（关闭时残留的 ping 回调）；如果中段连续出现就是 ping 也发不出去 → 连接早已死。

## 6. 已经走完的路径，不用再走

- ❌ `x-custom-keepalive` header — 不是 Doubao 协议的一部分，官方 APK 里没有
- ❌ 在 protobuf 字段 1、4 上猜值 — SAMICore 内部处理，Java 层看不到
- ❌ 找 `enable_speech_rejection` 字段 — dousha 一直发 false，官方 Java 代码里没找到对应配置（可能是被服务器忽略的旧字段）

## 7. 当前 dousha 的协议层契合度

| 维度 | 官方 | dousha | 状态 |
|---|---|---|---|
| WS PING | 3s（QUIC 路径明示）| 3s | ✅ |
| StartSession config 关键字段 | 20+ | 8 | 🟡 补了主要的 4 个 |
| finish_audio 标记 | 是 | 是 | ✅ |
| finish_wait_timeout | 10s | 10s | ✅ |
| frame_time_ms | 10ms | 20ms | ❌ |
| 客户端重试 | 7 次重试 + 320KB 缓存 | 一次性 retranscribe | 🟡 不同机制覆盖类似语义 |
| 多链路 | QUIC + WS | 纯 WS | ❌ |
| Segment 处理 | 走 SAMICore native（行为未知） | 客户端 rescue 启发式 | 🟢 实测能 work |
