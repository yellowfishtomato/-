# 缺陷修复与特性实现报告

提交账号：huangyufan；日期：2026-11-05。姓名、实际学习用时请提交者自行核对填写。

## 验收状态与证据边界

本报告基于真实上传的 v1.0 源码及补传的原始小样本。源码修复和第一阶段验证由助手在独立 Linux 工作区完成；第二阶段由用户在本地 Windows 执行已交付脚本，并提供真实输出。完整 Windows 日志与原始 JSON 保存在本地证据目录，报告区分实测与未执行项。

- 修复前独立复现集：18 项中 8 通过、10 失败，见 `evidence/before-tests.log`。
- 收到原始小样本后，原先完整验收暴露两处样本/断言冲突及一处并发测试配置问题；原始失败日志完整保留为 `evidence/original-first-full-ctest.log`。
- **当前默认验证集为 61 项**。其中两项课程断言按输入的合法性更正，并新增有效 GBK 与真实 CRLF 补充样本；并发测试修正了脏数据配置和线程 join 顺序。详细理由见 `docs/COURSE_FIXTURE_NOTES.md`，不能把这称为未修改课程断言全通过。
- 课程原始 Parser 源文件逐字节保留为单独目标 `csvp_course_parser_tests`。开启全部禁用项后，8 项中仍是 6 通过、2 个样本/断言冲突失败；见 `evidence/course-original-parser-audit.log`。
- 最终 Release / Debug / ASan / 100 次打乱复跑的状态和数量见 `evidence/VALIDATION.json` 与 `final-*.log`。原始 100k 三轮均 98,000 成功、2,000 跳过；全部错误原文、行号、原因已逐条核对。
- 原始 100k 同环境三轮平均：v1.0 为 6,512.84 ms，修复后 56.269 ms，约 115.7 倍。前后都用同一个实际上传文件；只能代表该环境和样本。
- Linux 使用 GCC 14.2 / CMake 4.1.2；用户 Windows 已使用 MSVC 19.44 / VS2022 x64 完成 Release、Debug 和脚本规定的 100 次复跑。原始 1 GB 两种模式均通过计数、完整错误日志核验及 <50,000,000 字节的内存门槛；具体数据见下表。Windows 有编译警告，不宣称 `/W4` 零告警。
- ASan 使用 `detect_leaks=0:halt_on_error=1` 检查地址错误。LeakSanitizer 在该环境明确报告不支持 ptrace，不能宣称 LSan 零泄漏。

## Part A：缺陷修复

### A-1 文件没有尾换行时丢失最后一行

- **复现**：`Regression.LastRowWithoutLF` 创建 `a,b\n1,2\n3,4`；旧版第二次读行返回 false。
- **根因**：`readLineFromFile()` 在块中找不到 LF 就直接返回 false，即使已读到合法的最后一条记录。
- **修复**：分块读取，EOF 前仍有字节则返回最后记录；只有无字节且无 I/O 错误才是正常 EOF。
- **证据**：修复前该项失败，修复后通过；`Feature.LongLineBlockBoundaryAndManyBlankLines` 同时验证跨块与无尾 LF。

### A-2 重复使用解析器时状态未重置及缓冲区泄漏

- **复现**：`Regression.ReparseResetsCounters` 用同一对象反复打开同一个文件；旧版行号和字节数逐次增长。
- **根因**：只清表头和偏移，未清行号、字节数、错误；每次 malloc 16 MB 覆盖旧指针，析构只能释放最后一次分配。解析器默认可复制还会复制资源指针。
- **修复**：文件由带 fclose 删除器的 unique_ptr 管理，输入缓冲由 vector 管理并复用；parse 一开始重置全部状态；禁止复制资源所有者。
- **证据**：重复解析测试通过，失败重开与空路径也清空元信息；ASan 地址错误测试无报告。LSan 在本环境不可用，此处泄漏根因另有明确所有权分析支持。

### A-3 列数错误穿透 skip_bad_rows

- **复现**：`Regression.SkipColumnMismatchAndKeepFollowingRows` 用三条数据，其中中间一条缺列；旧版直接抛异常。
- **根因**：列数检查位于坏行处理逻辑外，异常不受 skip_bad_rows 控制。异常分支还创建但没有保存 RowError，可能丢详情。
- **修复**：解析错误、列数错误、校验错误统一进入行错误路径；true 时先完整记录再跳过，false 保留旧有的遇错抛异常行为。
- **证据**：中间坏行准确计数，后续合法行仍导入；`Feature.MemoryCapAndFailFastAreExplicit` 验证 fail-fast 不被改成悄悄继续。

### A-4 GBK 字节边界被当成分隔符

- **复现**：`Regression.GBKPipeTrailByteIsNotDelimiter` 使用 `|` 分隔符和合法字节对 `81 7c`；旧版按单字节把第二个字节切开。
- **根因**：编码配置未参与字段扫描；原 isTrailingByte 只描述 UTF-8 且未使用。
- **修复**：GBK 的 lead 81–FE 与 trail 40–FE（排除 7F）作为一组消费；UTF-8 检查长度、后续字节、过长编码、代理区和码点上界。错误编码产生可恢复坏行。
- **证据**：GBK 分隔符冲突、非法尾字节及 UTF-8 非法序列测试通过。
- **事实核对**：逗号 2c 不属于合法 GBK trail 范围，不能把非法字节对当成合法“逗号碰撞”证据。保留原始 GBK 字节，不声称已转成 UTF-8。

### A-5 类型转换静默变成 0、半转换、溢出和非有限数

- **复现**：`Regression.NumericConversionRejectsInvalidAndPartial`；旧版 N/A 返回 0，12abc 被 stoi 接受为 12。`Regression.ValidatorRejectsOverflowAndNonFinite` 暴露范围溢出、NaN/Inf 被接受。
- **根因**：吞掉 stoi 异常、使用无错误信息的 atof；校验器 strtol/strtod 未验证溢出和有限性，Windows long 与 Linux long 的范围也不同。
- **修复**：整数用 from_chars，固定 int 范围，要求完全消费；浮点要求完全消费、无 ERANGE、isfinite。Row 非法值抛 invalid_argument，越界抛 out_of_range，0 保持合法；校验器返回明确 CellError。复用原有范围/正则框架，没有重做一套校验体系。
- **证据**：上述两个用例及原有 Validator 用例通过。范围比较不再把 double 上下界强转 long 截断。

### A-6 错误数量大时内存无界增长

- **复现**：旧版 error_limit=0 会无界保存原始行与每个错误字段；旧 bench 在全部结果生成后才抽样，无法限制导入阶段内存。
- **根因**：只在报告输出阶段限流；错误容器与文件错误数线性增长。
- **修复**：每条错误同步写入 JSONL；内存预览同时受 error_limit 和 error_memory_limit 限制。0 表示无条数限制，但仍受字节预算限制。预算估算包含字符串容量、容器元素和分配余量；不保留所有成功行。
- **证据**：`Feature.AllErrorsPersistDespitePreviewLimit` 产生 20,000 坏行，只留 3 条预览，逐条核对日志行号和原文，完整错误数仍为 20,000；零预览预算仍保存全部详情。1 GB 补充测试有 10,000 条完整错误日志。

### A-7 重复读大块造成严重吞吐下降；大偏移和行号窄化

- **复现**：同一合成 10k 文件，见 `evidence/synthetic-10k-before.txt` 和 `synthetic-10k-after.json`。
- **根因**：每读一行都 fseek 并 fread 最多 16 MB，只消费第一行，后续数据下次又读；Windows 上 long 偏移还可能截断。行号使用 int。
- **修复**：64 KB 顺序读取、保留未消费部分、memchr 找换行；每字节只顺序读取一次，不再依赖文件长度或 fseek。行号及计数使用 size_t，目标为 x64。
- **证据**：补充 10k 基准前后对比；跨 64 KB 边界和 100,000 空行测试；编译期断言行号接口为 size_t。尚未用超过 INT_MAX 行的真实文件做计数压力验证。

### A-8 双引号转义、尾部空字段和字段空格处理

- **复现**：`Regression.QuotesAndTrailingEmpty`；旧版把双引号对里的第一个当闭合。最后一列是引号字段时可能再补一列；普通字段只在整行最后才修剪尾空格。
- **根因**：字段状态没有区分转义引号和闭合引号，字段追加逻辑重复，trim 未逐字段执行。
- **修复**：每轮完整解析一个字段；双引号对转成一个字面引号；字段闭合后要求分隔符或行尾；每个非引号字段独立 trim；尾分隔符产生一个空字段，引号字段内容保持原样。
- **证据**：引号/空列/trim 测试，及 `Feature.RandomizedQuotedRowsRoundTrip` 的 300 行、1,200 字段往返核对，覆盖引号、逗号、空格、tab、回车、LF/CRLF、无尾换行。

### A-9 错误原文被重组，语法错误被当成 EOF

- **复现**：旧代码用逗号拼接已解码字段，无法还原引号、空格、实际分隔符或 BOM；解析失败返回 false 导致管道误以为文件结束，后续行丢失。
- **根因**：缺少独立原始记录与可恢复错误状态。
- **修复**：rawLine 保留实际字节（只移除记录终止符），BOM 只在解析视图中跳过。可恢复坏行 readRow 返回 true 并置 invalid；管道继续处理下一条物理记录。致命 I/O/超长错误明确标记失败，不伪装完成。
- **证据**：`Feature.RecoverAfterMalformedCSVAndEncoding`、`Feature.NullBytesAndInvalidUTF8AreRecoverableBadRecords`、`Feature.UTF8BOMIsSyntaxButOriginalBytesRemainAvailable` 和超长记录测试。

### A-10 统计信息数据竞争、同步结果被零原子计数覆盖

- **复现**：`Regression.SyncStatsReflectActualImport` 中已导入两行但 stats 返回 0；旧 stats 读取可能由导入线程写入的普通 Stats 对象。
- **根因**：普通成员和原子成员混用，热计数没有在同步路径更新。
- **修复**：同步和后台走同一执行核心；发布字段均为原子，生命周期控制使用短锁；stats 不再读取并发修改的普通对象。total 根据本次读取的成功/跳过数计算，完成后与 Result 一致。
- **证据**：原有 StatsThreadSafety/StatsAtomicRead、4 个统计读线程与导入并发测试均通过。压力测试不是 ThreadSanitizer 证明；结论同时依赖共享状态的原子/锁设计审查。
- **缓存说明**：将热统计区与停止标志区分开；本设计的三个热计数由同一任务线程更新，不臆称“每个计数器独占缓存行”必然更快。

### A-11 无表头导入与空行递归

- **复现**：`Regression.HeaderlessRulesUseRuleCount`；旧版无表头时仍与空 header 比列数。连续空行递归 readRow，极端情况下增加栈深度。
- **修复**：无表头时用规则数，规则也为空时用首个数据记录确定列数；空行迭代跳过，物理行号仍准确。独立 Validator 对缺失的必填列也返回错误。
- **证据**：无表头、跨块长行和 100,000 连续空行测试。

### 保留并验证的 CRLF 处理

原有“移除 CRLF 终止符中的一个 CR”本身有必要，不能见到删 CR 就删除。新实现仍只在确实读到 LF 时移除前一个 CR；引号字段内部的 CR 保留。`Regression.QuotedCarriageReturnIsData` 在修复前就通过，属于保护性回归，不虚报为新发现缺陷。补传原文件已确认没有任何 CR 字节，且用户本地 Format-Hex 结果相同。原始断言要求凭空出现 CR，故保留失败证据；正常 CRLF/字段 CR 的要求由单独标注的补充标准样本验证，详见 COURSE_FIXTURE_NOTES.md。

## Part B：特性实现

### B-1 importStreaming

- 调用时只复制路径、移动回调、登记任务并启动线程；打开、读、解析、校验均在后台执行。
- 每处理完 1,000 条非空数据记录调用 progress；成功与跳过都计数；不额外调用末尾不足 1,000 的回调。
- false 返回已完成部分，cancelled=true；停止请求也每条记录检查。回调异常与资源异常由 promise 的异常通道交付。
- 不使用 std::async，避免调用方销毁 future 时被隐式等待阻塞；线程不捕获 this。路径来自临时 string.c_str() 也已复制。
- 每个管道最多一个活动任务，可在正常完成后复用。忙碌时拒绝第二个任务，不设置无界任务队列。

### B-2 shutdown 与 pendingCount

- stop_requested 原子置位；condition_variable 只等待任务结束事件，最多 timeout，负值按零处理。
- pendingCount 读取尚未结束的导入任务数（0/1），不假装知道尚未扫描的文件还有多少行。
- 共享 State、配置、规则、promise、路径和回调由工作线程持有，超时后销毁前端对象不会导致内部悬空访问；结束时资源自然释放。
- 只有任务登记/结束和条件等待持有控制锁，CSV 热循环不持有这把锁。回调里调用 shutdown 会识别当前工作线程并直接返回，避免等待自己。
- shutdown 是终止操作，之后不接受新任务。不能安全强杀任意 C++ 线程；回调必须最终返回，外部引用捕获的对象需活到 future 完成。
- 验证：阻塞回调中 shutdown(20ms) 在测试容差内返回且 pending=1；销毁管道后解除回调阻塞，future 正常返回取消结果。另测回调自停、异常、忙碌拒绝、销毁 future 和任务计数恢复。

## Part C：大文件内存策略与补充压力测试

### 内存、背压与完整性

- 64 KB 输入块 + 当前原始行 + 当前 Row + 受限错误预览 + 小型日志输出缓冲；不保存所有成功行。
- 日志同步写入形成自然背压：磁盘慢就降低读入速度，没有生产者无限排队的问题。
- 正常 EOF 时满足 rows_imported + rows_skipped = 处理的数据记录数；每个 skipped 都有完整日志记录。日志写入/flush 失败显式失败，不能把错误丢掉后仍报告成功。
- 原始字节十六进制保存，可完整反解 GBK/非法编码；错误原因、列号和物理行号也保存。内存预览受限不会减少错误日志。
- 单条记录仍有 16 MB 上限。这里的 <50 MB 验收面向题目指定的 5 列、约 100 字节记录文件，不承诺任意超长字段或任意列数 CSV 都满足同一峰值。

### Linux 补充实测（不是 Windows 原始文件验收）

补充生成命令：

```bash
python scripts/make_stress_data.py ../stress/synthetic_teacher_distribution_1gb.csv --rows 10000000 --dirty
./build-release/csvp_bench ../stress/synthetic_teacher_distribution_1gb.csv 1 evidence/synthetic-1gb.json --large
python scripts/verify_original.py ../stress/synthetic_teacher_distribution_1gb.csv evidence/synthetic-1gb.json
```

合成文件大小 1,003,898,922 字节，10,000,000 行数据，name 补齐到 78 字符，每 1,000 行 age=N/A；SHA-256 为 `89fa6c306b9730ea71a782da699c64cec1efc6b4097852bb457bc30abc9477d0`。这份文件在第一阶段仅作为独立补充测试。2026-11-05 用户在 Windows 对老师原始文件计算出的 SHA-256 与之完全一致，现已确认两者字节相同；仍保留原 synthetic 命名和历史来源，正式结果以下述用户 Windows 实测为准。

实际耗时、峰值和错误核对结果见 `evidence/synthetic-1gb*.json`、`synthetic-1gb*-verified.log`。两种模式均应为 9,990,000 成功、10,000 跳过、10,000 完整错误，只有 32 条内存预览。`synthetic-1gb-external-memory.log` 另以 /proc 的 VmHWM 做独立进程观察；正式结论使用进程自身的高水位指标，而非只看某一瞬间内存。

### Windows 原始数据验收：已完成

执行日期：2026-11-05；平台：Visual Studio Community 2022，MSVC 19.44.35222.0，x64。用户运行脚本，末尾返回 `Checks passed`。

| 模式 | 成功行 | 跳过行 / 完整错误数 | 控制台耗时 | 峰值工作集 |
|---|---:|---:|---:|---:|
| 同步 | 9,990,000 | 10,000 / 10,000 | 约 10.60 秒 | 4,669,440 字节，约 4.67 MB |
| 后台流式 | 9,990,000 | 10,000 / 10,000 | 约 11.33 秒 | 5,029,888 字节，约 5.03 MB |

- 数据文件为用户本机老师原始 `sample_1gb.csv`，大小 1,003,898,922 字节；两次 SHA-256 均为 `89fa6c306b9730ea71a782da699c64cec1efc6b4097852bb457bc30abc9477d0`。
- 两种模式均逐条核对 10,000 条错误的物理行号、错误原因和原始字节，通过 Python 核验；成功与坏行合计 10,000,000，没有把预览条数误当完整错误数。
- 峰值来自 GetProcessMemoryInfo 的 PeakWorkingSetSize，包含导入进程的解析、校验、错误预览和日志缓冲，均严格低于 50,000,000 字节。bench 及核验脚本也检查 PeakPagefileUsage 的门槛；控制台摘录未给其精确值，不能补造，具体数值见本地 1gb-sync.json / 1gb-streaming.json。
- 控制台耗时是打印舍入值，最终精度以本地 JSON 为准；下方可由交付脚本追加原始 JSON 数据。
- 原始 100k 三次均 98,000 成功、2,000 跳过和完整记录。控制台耗时 57.7076 / 90.2446 / 52.6973 ms，平均约 66.883 ms。
- 本次命令未使用 `-WithASan` 或 `-WithBaseline`，因此不宣称 Windows ASan 通过，也不编造本次 Windows 修复前对比。Linux 的前后对比与 ASan 地址检查单独记录。

本地完整证据目录：

```text
D:\HUAZHONG\WPS office course\KDevelop-Train\LessonCode\week01\homework\csv-import-pipeline-fixed-20261105-163726-8eb168\evidence\windows-20261105-164201
```

助手收到的末尾摘录及初始构建输出另存为 `evidence/windows-user-console-summary.log`、`windows-user-initial-console.log`；摘要结构化为 `windows-user-measurements.json`。这些明确标为用户提供的摘录，不替代本地完整日志，提交时应将上述 Windows 证据目录一起打包。

<!-- WINDOWS_RAW_METRICS_BEGIN -->
本机原始 JSON 的详细数值可由最终打包脚本自动补在此处。
<!-- WINDOWS_RAW_METRICS_END -->

## 性能优化与告警

- 大头优化为取消逐行重复读取整块、改为顺序读取；合法字段的校验路径不再复制完整 raw_value 到临时 CellError；解析后的字段用 move 传入 Row。
- 合成 clean 10k、973,919 字节、同一文件/同一 GCC Release 配置、各 3 次：原版平均 311.238 ms，修复后的实际结果见 `synthetic-10k-after.json`。只说明这个环境和样本上的改善，不外推成 Windows 或任意数据分布的固定倍率。
- GCC `-Wall -Wextra -pedantic` 下修复后完整构建日志无告警；原有测试及 bench 的 FieldRule 初始化补齐默认成员，避免有意省略字段产生的告警，没有关闭告警来隐藏问题。
- Windows 实际出现 C4324（State 的对齐填充）、C4267（逐字节保留的课程原测试将 size_t 赋给 int）、C4310（构造非 ASCII 测试字节的显式 char 转换）。它们没有阻止构建或验收，但必须在报告中记录，不宣称 Windows 零告警。中文构建提示的乱码是日志编码显示问题，原始文件哈希和逐行字节核验已通过。
- 未运行 clang-tidy 或 ThreadSanitizer，不声称通过它们。

## Git 历史与附件

`evidence/git-log.txt` 记录从原始快照、失败复现、修复、特性、测量到报告，以及补传原始数据后的核验与测试更正。`history.bundle` 含可克隆的真实迭代历史，便于逐次审查；没有伪造作者、日期、截图或未执行的 Windows 结果。

主要附件：Linux 修复前后及地址检查日志、课程原始断言冲突证据、原始 100k 前后对比、用户 Windows 的 Release/Debug/100 次复跑日志、原始 1 GB 两种模式 JSON 和完整错误 JSONL、逐条核验日志。
