# CSV Import Pipeline：周作业实现

C++17 / CMake >= 3.16。基于上传的 v1.0 工程修复；保留内嵌 GoogleTest，支持 MSVC 2022 x64 和 GCC。

原始小样本和 100k 验证已补齐；默认验证集为 61 项。**课程原始 GBK/CRLF 两项断言与文件字节矛盾**，更正方式和原始失败证据见 [样本核对说明](docs/COURSE_FIXTURE_NOTES.md)。原始断言另有完整保留的审查目标，不能将修订测试的通过称为未修改课程断言全通过。

用户已于 2026-11-05 在 Windows / MSVC 2022 上完成原始 1 GB 验收：同步约 10.60 秒、峰值工作集 4.67 MB；流式约 11.33 秒、5.03 MB。两次均成功 9,990,000 行、完整记录并核对 10,000 条坏行；详见 [最终报告](docs/REPORT.md)。

## 在 Windows 上运行

包内已有原始小样本和补充标准样本。在本目录打开 PowerShell即可构建测试；若指定 `CSVP_TEST_DATA_DIR`，它只影响原始样本路径，补充样本仍从本工程的 data/reference 读取：

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 "-DCSVP_TEST_DATA_DIR=D:/你的路径/data"
cmake --build build --config Release --parallel
ctest --test-dir build -C Release --output-on-failure
```

完整验证脚本会构建 Release/Debug、运行上述修订测试及 100 次打乱复跑，使用原始 1 GB 数据实测峰值并核对全部 10,000 条错误，证据写入独立目录。需要已安装 Git、CMake、Python。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Run-WindowsChecks.ps1 -DataDir "D:\你的路径\data"
# 已装 VS 的 C++ AddressSanitizer 组件时，可加 -WithASan。
# 需要原始工程前后性能对比时，可再加 -WithBaseline；会从 history.bundle 单独克隆基线。
```

PowerShell 脚本已由用户在 Windows / MSVC 2022 上完整执行并返回 Checks passed。每项非零退出码都会中止脚本，不能把只完成前几项当作全部通过。

## 接口和行为

```cpp
#include <csvp/pipeline.h>
csvp::ImportPipeline::Config cfg;
cfg.skip_bad_rows = true;
cfg.error_limit = 32;                    // 内存预览条数
cfg.error_memory_limit = 256 * 1024;     // 预览内存预算
// cfg.error_log_path = "unique-errors.jsonl"; // 指定的日志文件须尚不存在
csvp::ImportPipeline pipeline(cfg, {{"id", csvp::FieldType::Int, true}});
auto future = pipeline.importStreaming("data.csv", [](size_t processed) {
    return processed < 10000;            // 每 1000 行在后台线程调用
});
// pipeline.shutdown(std::chrono::milliseconds(100));
// auto pending = pipeline.pendingCount(); // 未完成导入任务数：0 或 1，不是剩余行数
auto result = future.get();
```

- 同一管道最多一个活动导入；空闲后可重复导入。并发启动第二个任务会抛 `logic_error`。
- `shutdown` 为终止操作，返回后不再接受任务。超时不强杀线程，后台共享状态独立于前端对象存活；完成后释放资源。
- 回调必须最终返回；回调捕获的外部对象须活到 future 完成。回调内调用 shutdown 不等待自身；回调异常经 future 传递。
- `skip_bad_rows=false` 保留原有的遇错抛异常行为，异常消息包含已落盘的错误日志位置；true 时可恢复的坏行写日志后继续。
- `completed` 只表示真正读到 EOF；取消、失败和文件打不开都有明确标志。磁盘写入失败、资源异常经异常通道报告。
- `Row::toInt/toDouble` 的非法值抛 `invalid_argument`，越界抛 `out_of_range`；合法 0 正常返回，拒绝半转换、溢出和非有限数。
- `readRow` 对可恢复的语法/编码错误返回 true 且 `row.isValid()==false`，下一次仍可继续；false 表示 EOF 或致命错误，应检查 `lastError()`。
- 支持 UTF-8/GBK 字节边界，不做字符集转码。16 MB 行上限仍保留；不支持引号内跨物理行；超长记录明确失败，不伪装成 EOF。
- 空物理行跳过，物理行号包含表头和空行；导入统计只计非空数据记录。统计计数无普通变量数据竞争，运行中为近似快照，任务完成后与 Result 一致。

## 完整错误日志

`Result.errors` 是受条数和字节预算限制的预览，`errors_recorded` 才是完整错误数。所有错误都写到 `error_log_path` 指定的 JSONL，未指定时自动在系统临时目录创建唯一文件。

每条含物理行号、`raw_line_hex` 和列错误（列号、错误码、原因、`raw_value_hex`）。原始字节使用十六进制保存，支持 GBK、引号、回车和非法编码，避免重组 CSV 丢信息。原始记录不含行结束符。

```python
import json
entry = json.loads(open("errors.jsonl", encoding="ascii").readline())
raw_bytes = bytes.fromhex(entry["raw_line_hex"])
```

## 压测与证据

```powershell
.\build\Release\csvp_bench.exe "D:\原始data\sample_1gb.csv" 1 evidence\original-1gb.json --large
python .\scripts\verify_original.py "D:\原始data\sample_1gb.csv" evidence\original-1gb.json
```

`--large` 检查文件字节数、9,990,000 成功行、10,000 错误行、完整日志计数和进程峰值 < 50,000,000 字节。Windows 同时记录 PeakWorkingSetSize 和 PeakPagefileUsage；Linux 使用 getrusage 的峰值 RSS。测量来自单独的 Release 压测进程，包含解析、预览和错误日志缓冲；不使用 ASan 进程的内存作正式判定。

`--streaming` 可验证后台模式。Python 核验在压测结束后独立运行，流式对照原 CSV 全部错误行并输出 SHA-256。

Git 提交记录见 evidence/git-log.txt；完整迭代历史在 history.bundle：

```bash
git clone history.bundle csvp-review
```

内嵌依赖及许可证保持原样；本工程沿用原项目 BSD-3-Clause 说明。

## 保留的课程原始断言审查

```powershell
.\build\Release\csvp_course_parser_tests.exe --gtest_also_run_disabled_tests
```

该目标使用课程原始 Parser 测试源码，当前原始样本下 6 通过、2 失败。默认 CTest 使用已说明理由的修订断言及补充标准样本；两者证据分别保留。
