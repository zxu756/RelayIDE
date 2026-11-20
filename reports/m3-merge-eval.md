# RelayIDE M3 语义合并去留评估报告

## 1. 清单校验和、运行环境与总耗时（验收第 13、14 行）

- **运行模式**：`full`
- **`Scripts/eval/merge-corpus/repos.tsv` sha256**：`ed9dc89dacca8e09bcacb17678bc5fe65770815f9fe61d0d194a293b3608d404`
- **`Fixtures/merge-corpus/cases.tsv` sha256**：`708ef8516ab5ff234fd998683a7c83fc3b49931625a23d40af21e0548575a381`
- **`Fixtures/merge-cases/CLASSIFIED.tsv` sha256**：`2752366614bddcef7b054689a105acf20b1a77db7453bcc64139f18901a3f3a0`
- **机器与系统**：`macOS 27.0.1 (26A434); Apple M4 (10 cores)`
- **开始时负载（1 / 5 / 15 分钟 loadavg）**：`5.40 6.03 9.17`

### 工具与固定解析器版本及路径

| 组件 | 路径与版本 / 校验和 |
|---|---|
| 基线 `git` | `/usr/bin/git (git version 2.54.0 (Apple Git-157))` |
| 产品命令行（经 `relay-cli.sh`） | 入口 `<repo>/Scripts/acceptance/relay-cli.sh`；二进制 `<repo>/.build/release/RelayIDE`；提交 `73305a23a1c3c6c298289f58e0d83a306a04b46c`；`sha256=6c83cb6211ae084c16a15700fad040a36271b4d240ae96d6e48e9303edaec5bc` |
| 发布的命令 `caller` PATH 命中的工具 | `python3`: `/usr/bin/python3 (Python 3.9.6)`；`tsc`: `not-found (not-found)`；`node`: `/opt/homebrew/opt/node@22/bin/node (v22.23.4)`；`git`: `/opt/homebrew/bin/git (git version 2.56.0)` |
| 发布的命令 `eval-python-first` PATH 命中的工具 | `python3`: `~/.local/share/uv/python/cpython-3.14.9-macos-aarch64-none/bin/python3 (Python 3.14.9)`；`tsc`: `not-found (not-found)`；`node`: `/opt/homebrew/opt/node@22/bin/node (v22.23.4)`；`git`: `/opt/homebrew/bin/git (git version 2.56.0)` |
| 固定解析器 `RELAY_EVAL_PYTHON` | `~/.local/share/uv/python/cpython-3.14.9-macos-aarch64-none/bin/python3.14 (Python 3.14.9)` |
| 固定解析器 Swift | `/usr/bin/swiftc (Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1); Target: arm64-apple-macosx27.0.0)` |
| 固定解析器 `RELAY_EVAL_TYPESCRIPT` | `$RELAY_MERGE_CORPUS_DIR/node/node_modules/typescript (typescript 5.9.3; node /opt/homebrew/opt/node@22/bin/node v22.23.4)` |
| 声明级引擎可执行文件 | `<repo>/Scripts/eval/merge-eval/.build/release/relay-merge-eval`；提交 `73305a23a1c3c6c298289f58e0d83a306a04b46c`；`sha256=fadad179a8202e7c58c62cb4f38d1a5b53ce4ac1bf8f25ca21a7a7a42cacb6da` |
| 对照工具 `mergiraf` | `/opt/homebrew/bin/mergiraf`（`mergiraf 0.20.0`）；`sha256=f34095937903f55ba4f446b40bed71fc57250ab9a2eaad31fb48140f0e66b6ee` |

### 各工具耗时与整份总耗时（验收第 14 行）

| 阶段 / 工具 | 墙钟耗时（秒） |
|---|---:|
| 固定用例检查与分类（`fixed_cases`） | 14.08 |
| 发布的命令（`caller` PATH） | 43.42 |
| 发布的命令（`eval-python-first` PATH） | 72.61 |
| 声明级引擎（`ThreeWaySemanticASTMerger`） | 39.90 |
| 对照工具（`mergiraf`） | 46.03 |
| 语料分类与固定解析器校验（`classify.py`） | 66.78 |
| **整份评估总耗时（`total`）** | 308.34 |

## 2. 验收第 6 行：发布的命令在冲突集上（每种语言五类，两种 PATH）

冲突集分母内“人工版本等于左 / 右”基线（`git` 行统计）：Python 左 91 / 右 8（分母 330），Swift 左 73 / 右 40（分母 377），TypeScript 左 122 / 右 20（分母 611），合计左 286 / 右 68（分母 1318）。

| 工具 / PATH | 语言 | 总数 | 排除（人工不过解析） | 分母 | 相同（`same`） | 相同占比 | 干净但不同 | 副计数：`ws_equal` | 副计数：`human_eq` 左/右 | 仍报冲突 | 拒绝（退出 3/4） | 输出损坏 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| `git` | `python` | 356 | 26 | 330 | 0 | 0.00% | 0 | 0 | 0 / 0 | 330 | 0 | 0 |
| `git` | `swift` | 476 | 99 | 377 | 0 | 0.00% | 0 | 0 | 0 / 0 | 377 | 0 | 0 |
| `git` | `typescript` | 622 | 11 | 611 | 0 | 0.00% | 0 | 0 | 0 / 0 | 611 | 0 | 0 |
| `git` | `all` | 1454 | 136 | 1318 | 0 | 0.00% | 0 | 0 | 0 / 0 | 1318 | 0 | 0 |
| `published_caller` | `python` | 356 | 26 | 330 | 1 | 0.30% | 1 | 0 | 0 / 0 | 328 | 0 | 0 |
| `published_caller` | `swift` | 476 | 99 | 377 | 0 | 0.00% | 1 | 1 | 0 / 0 | 376 | 0 | 0 |
| `published_caller` | `typescript` | 622 | 11 | 611 | 0 | 0.00% | 0 | 0 | 0 / 0 | 611 | 0 | 0 |
| `published_caller` | `all` | 1454 | 136 | 1318 | 1 | 0.08% | 2 | 1 | 0 / 0 | 1315 | 0 | 0 |
| `published_evalpy` | `python` | 356 | 26 | 330 | 1 | 0.30% | 1 | 0 | 0 / 0 | 328 | 0 | 0 |
| `published_evalpy` | `swift` | 476 | 99 | 377 | 0 | 0.00% | 1 | 1 | 0 / 0 | 376 | 0 | 0 |
| `published_evalpy` | `typescript` | 622 | 11 | 611 | 0 | 0.00% | 0 | 0 | 0 / 0 | 611 | 0 | 0 |
| `published_evalpy` | `all` | 1454 | 136 | 1318 | 1 | 0.08% | 2 | 1 | 0 / 0 | 1315 | 0 | 0 |

## 3. 验收第 7 行：发布的命令在干净回归集上（退出 3 逐例原因与 `git_parses`）

| 工具 / PATH | 语言 | 总数 | 排除（人工不过解析） | 分母 | 退出 0 且与 `git` 相同 | 退出 0 但与 `git` 不同 | 分母内退出 3 | 其中 `git_parses=1`（误拒） | 分母外退出 3 | 退出 1 / 4 / 其他 | 输出损坏 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `git` | `python` | 167 | 17 | 150 | 150 | 0 | 0 | 0 | 0 | 0 | 0 |
| `git` | `swift` | 167 | 40 | 127 | 127 | 0 | 0 | 0 | 0 | 0 | 0 |
| `git` | `typescript` | 166 | 0 | 166 | 166 | 0 | 0 | 0 | 0 | 0 | 0 |
| `git` | `all` | 500 | 57 | 443 | 443 | 0 | 0 | 0 | 0 | 0 | 0 |
| `published_caller` | `python` | 167 | 17 | 150 | 148 | 0 | 2 | 2 | 17 | 0 | 0 |
| `published_caller` | `swift` | 167 | 40 | 127 | 127 | 0 | 0 | 0 | 40 | 0 | 0 |
| `published_caller` | `typescript` | 166 | 0 | 166 | 97 | 0 | 69 | 69 | 0 | 0 | 0 |
| `published_caller` | `all` | 500 | 57 | 443 | 372 | 0 | 71 | 71 | 57 | 0 | 0 |
| `published_evalpy` | `python` | 167 | 17 | 150 | 150 | 0 | 0 | 0 | 17 | 0 | 0 |
| `published_evalpy` | `swift` | 167 | 40 | 127 | 127 | 0 | 0 | 0 | 40 | 0 | 0 |
| `published_evalpy` | `typescript` | 166 | 0 | 166 | 97 | 0 | 69 | 69 | 0 | 0 | 0 |
| `published_evalpy` | `all` | 500 | 57 | 443 | 374 | 0 | 69 | 69 | 57 | 0 | 0 |

### 3.1 分母内退出 3 的干净回归文件逐例清单（`caller` 71 例，`eval-python-first` 69 例）

| 用例 | 语言 | `caller` 退出码 | `evalpy` 退出码 | `git_parses` | 原因 |
|---|---|---:|---:|---:|---|
| `k00005` | `python` | 3 | 0 | 1 | "Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File ""<temp>"", line 1694 \| match state: \| ^ \| SyntaxError: invalid syntax" |
| `k00161` | `python` | 3 | 0 | 1 | "Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File ""<temp>"", line 143 \| except ipapi.TryNext, exc: \| ^ \| SyntaxError: invalid syntax" |
| `k00344` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :99 \| return <div>loading</div>; \| ^^^^^^ \| } |
| `k00346` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :52 \| <ApolloConsumer> \| {(client) => { \| ^ |
| `k00348` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :42 \| const wrapper = ({ children }: any) => ( \| <MockedProvider mocks={mocks}>{children}</MockedProvider> \| ^^^^^ |
| `k00351` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :97 \| <ol> \| {data!.list.map(item => <Item key={item.id} id={item.id}/>)} \| ^ |
| `k00352` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :68 \| { wrapper: ({ children }) => ( \| <MockedProvider mocks={mocks}> \| ^^^^^ |
| `k00353` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :85 \| constructor( \| public readonly client: ReturnType<typeof useApolloClient>, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00354` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :71 \| { wrapper: ({ children }) => ( \| <MockedProvider mocks={mocks}> \| ^^^^^ |
| `k00357` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :104 \| render() { \| return <Container first={this.state.first} />; \| ^^^^^ |
| `k00358` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :61 \| { wrapper: ({ children }) => ( \| <MockedProvider mocks={mocks}> \| ^^^^^ |
| `k00361` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :53 \| constructor( \| public readonly cache: InMemoryCache, \| ^^^^^^^^^^^^^^^^^^^^ |
| `k00369` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :344 \| delete this.queryDocuments[mutationId]; \| resolve(<ApolloQueryResult<T>>result); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00370` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :344 \| delete this.queryDocuments[mutationId]; \| resolve(<ApolloQueryResult<T>>result); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00372` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :340 \| delete this.queryDocuments[mutationId]; \| resolve(<ApolloQueryResult<T>>result); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00379` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :300 \| delete this.queryDocuments[mutationId]; \| resolve(this.transformResult(<ApolloQueryResult<T>>result)); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00383` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :11 \| import mapValues = require('lodash/mapValues'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import cloneDeep = require('lodash/cloneDeep'); |
| `k00384` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :21 \| import isEqual = require('lodash/isEqual'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript import equals declaration is not supported in strip-only mode |
| `k00385` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :11 \| import forOwn = require('lodash/forOwn'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import isEqual = require('lodash/isEqual'); |
| `k00386` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :11 \| import mapValues = require('lodash/mapValues'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import cloneDeep = require('lodash/cloneDeep'); |
| `k00387` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :16 \| import isUndefined = require('lodash/isUndefined'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import isString = require('lodash/isString'); |
| `k00388` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :4 \| import assign = require('lodash/assign'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import isequal = require('lodash/isEqual'); |
| `k00389` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :1 \| import isNull = require('lodash.isnull'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import isUndefined = require('lodash.isundefined'); |
| `k00391` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :47 \| import assign = require('lodash.assign'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript import equals declaration is not supported in strip-only mode |
| `k00392` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :6 \| import forOwn = require('lodash.forown'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import isEqual = require('lodash.isequal'); |
| `k00393` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :6 \| import forOwn = require('lodash.forown'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import isEqual = require('lodash.isequal'); |
| `k00394` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :20 \| import assign = require('lodash.assign'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript import equals declaration is not supported in strip-only mode |
| `k00395` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :7 \| import forOwn = require('lodash.forown'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import assign = require('lodash.assign'); |
| `k00396` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :38 \| import assign = require('lodash.assign'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript import equals declaration is not supported in strip-only mode |
| `k00397` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :7 \| import forOwn = require('lodash.forown'); \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| import assign = require('lodash.assign'); |
| `k00398` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :95 \| constructor( \| >     private readonly options?: { \| /** |
| `k00399` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :17 \| constructor( \| private readonly routesMapper: RoutesMapper, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00400` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :78 \| constructor( \| private readonly container: NestContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00404` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :104 \| class SecondService { \| constructor(public readonly loggerService: LoggerService) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00408` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :90 \| constructor(protected readonly options: Required<KafkaOptions>['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00409` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :67 \| constructor(private readonly options: Readonly<GrpcOptions>['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00415` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :67 \| constructor(private readonly options: Readonly<GrpcOptions>['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00416` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :72 \| constructor( \| private readonly _metatype: Type<any>, \| ^^^^^^^^^^^^^^^^^^^^ |
| `k00418` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :47 \| constructor(private readonly options: NatsOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00422` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :44 \| constructor(private readonly options: TcpOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00424` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :54 \| constructor(private readonly options: GrpcOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00426` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :29 \| constructor( \| private readonly container: NestContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00428` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :29 \| constructor(private readonly options: RedisOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00429` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :52 \| constructor(protected readonly options: KafkaOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00432` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :80 \| constructor(private readonly options?: { preview: boolean }) {} \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript parameter property is not supported in strip-only mode |
| `k00433` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :65 \| constructor( \| protected readonly container: NestContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00434` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :45 \| constructor(private readonly routePathFactory: RoutePathFactory) {} \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript parameter property is not supported in strip-only mode |
| `k00443` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :55 \| constructor(protected readonly options: KafkaOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00445` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :31 \| constructor( \| private readonly _applicationConfig: ApplicationConfig = undefined, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00446` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :31 \| constructor(protected readonly options: RedisOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00447` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :26 \| constructor( \| private readonly container: NestContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00450` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :23 \| constructor(private ioAdapter: WebSocketAdapter \| null = null) {} \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript parameter property is not supported in strip-only mode |
| `k00451` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :54 \| constructor( \| private readonly metadataScanner: MetadataScanner, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00452` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :66 \| container: NestContainer, \| private readonly httpAdapter: HttpServer, \| ^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00453` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :60 \| constructor( \| private readonly container: NestContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00454` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :44 \| constructor( \| private readonly guardsContextCreator: GuardsContextCreator, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00457` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :42 \| constructor(protected readonly options: RmqOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00458` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :31 \| constructor( \| @Optional() protected context?: string, \| ^^^^^^^^^^^^^^^^ |
| `k00459` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :209 \| > export enum ResourceType { \| UNKNOWN = 0, \| ANY = 1, |
| `k00460` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :31 \| constructor(private readonly options: MqttOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00465` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :58 \| constructor( \| private readonly paramsFactory: IRouteParamsFactory, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00468` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :32 \| constructor( \| private readonly clientsContainer: ClientsContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00469` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :36 \| constructor(private readonly options: GrpcOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00471` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :51 \| container: NestContainer, \| private readonly httpAdapter: HttpServer, \| ^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00477` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :30 \| constructor(public depOne: DependencyOne, public depTwo: DependencyTwo) {} \| ^^^^^^^^^^^^^^^^^^^^^ \| } |
| `k00479` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :23 \| constructor(private readonly options: MicroserviceOptions['options']) { \| ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ \| super(); |
| `k00480` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :67 \| container: NestContainer, \| private readonly httpAdapter: HttpServer, \| ^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00481` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :35 \| constructor( \| private readonly container: NestContainer, \| ^^^^^^^^^^^^^^^^^^^^^^^^ |
| `k00487` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :200 \| > export enum DefinitionType { \| query = 'query', \| mutation = 'mutation', |
| `k00497` | `typescript` | 3 | 3 | 1 | "Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :102 \| <div> \| <div data-testid=""isFetching"">{String(isFetching)}</div> \| ^^^^" |
| `k00500` | `typescript` | 3 | 3 | 1 | Merged output failed syntax check (node stripTypeScriptTypes) and was suppressed to prevent file corruption: :131 \| class HandledError { \| constructor(public readonly value: any) {} \| ^^^^^^^^^^ |

### 3.2 分母外（人工版本过不了固定解析器，已排除）退出 3 的干净回归文件逐例清单（共 57 例）

| 用例 | 语言 | `caller` 退出码 | `evalpy` 退出码 | `git_parses` | 原因 |
|---|---|---:|---:|---:|---|
| `k00134` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 239 \| print sys_exit, \| ^ \| SyntaxError: Missing parentheses in call to 'print'. Did you mean print(sys_exit, end=" ")? |
| `k00135` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 639 \| print self.notebook_info() \| ^ \| SyntaxError: invalid syntax |
| `k00138` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 634 \| print self.notebook_info() \| ^ \| SyntaxError: invalid syntax |
| `k00146` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 209 \| nt.assert_true('dead' in [_ip.user_ns[x] for x in '_','__','___']) \| ^ \| SyntaxError: invalid syntax |
| `k00148` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 500 \| os.makedirs(new, mode = 0777) \| ^ \| SyntaxError: leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers |
| `k00149` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 247 \| exec s in user_ns \| ^ \| SyntaxError: Missing parentheses in call to 'exec' |
| `k00151` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 239 \| print os.linesep.join(lines) \| ^ \| SyntaxError: invalid syntax |
| `k00152` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 204 \| print 'Error in arguments:' \| ^ \| SyntaxError: Missing parentheses in call to 'print'. Did you mean print('Error in arguments:')? |
| `k00153` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 109 \| raise IOError,'File `%s` not found.' % name \| ^ \| SyntaxError: invalid syntax |
| `k00154` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 414 \| print html \| ^ \| SyntaxError: Missing parentheses in call to 'print'. Did you mean print(html)? |
| `k00155` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 436 \| os.makedirs(new, mode = 0777) \| ^ \| SyntaxError: leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers |
| `k00156` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 130 \| `self.hist_file`) \| ^ \| SyntaxError: invalid syntax |
| `k00159` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 401 \| os.makedirs(new, mode = 0777) \| ^ \| SyntaxError: leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers |
| `k00162` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 260 \| print '*'*77 \| ^ \| SyntaxError: Missing parentheses in call to 'print'. Did you mean print('*'*77)? |
| `k00164` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 95 \| print "This embedded IPython will not reactivate anymore once you exit." \| ^ \| SyntaxError: Missing parentheses in call to 'print'. Did you mean print("This embedded IPython will not reactivate anymore once you exit.")? |
| `k00165` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 354 \| raise KeyError,'user_ns dictionary MUST have a "__name__" key' \| ^ \| SyntaxError: invalid syntax |
| `k00167` | `python` | 3 | 3 | 0 | Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File "<temp>", line 335 \| raise KeyError,'user_ns dictionary MUST have a "__name__" key' \| ^ \| SyntaxError: invalid syntax |
| `k00192` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:93:51: error: expected 'let' in conditional \| 91 \| \| 92 \| func makeConfig(ruleConfiguration: AnyObject?, _ identifier: String) -> Configuration? { \| 93 \|     if let ruleConfiguration = ruleConfiguration, ruleType = masterRuleList.list[identifier] { |
| `k00218` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:31:32: error: 'where' clause next to generic parameters is obsolete, must be written following the declaration's type \| 29 \|  /// - parameters: \| 30 \|  ///   - signal: A signal to observe after starting the producer. \| 31 \|  public init<S: SignalProtocol where S.Value == Value, S.Error == Error>(signal: S) { |
| `k00219` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:784:58: error: single argument function types require parentheses \| 782 \| \| 783 \|      var counter = 0 \| 784 \|      let transform = { (signal: Signal<Int, NoError>) -> Signal<Int, NoError> -> Signal<(Int, Int), NoError> in |
| `k00220` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:42:36: error: unknown attribute 'noescape' \| 40 \| extension PropertyProtocol { \| 41 \|  /// Lifts a unary SignalProducer operator to operate upon PropertyProtocol instead. \| 42 \|  private func lift<U>(_ transform: @noescape (SignalProducer<Value, NoError>) -> SignalProducer<U, NoError>) -> Property<U> { |
| `k00225` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:29:15: error: attribute can only be applied to types, not declarations \| 27 \|  /// if a terminating event is sent to the observer. The Signal itself will \| 28 \|  /// remain alive until the observer is released. \| 29 \|  public init(@noescape _ generator: Observer -> Disposable?) { |
| `k00226` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:29:15: error: attribute can only be applied to types, not declarations \| 27 \|  /// if a terminating event is sent to the observer. The Signal itself will \| 28 \|  /// remain alive until the observer is released. \| 29 \|  public init(@noescape _ generator: Observer -> Disposable?) { |
| `k00227` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:31:33: error: function types cannot have argument labels; use '_' before 'identifier' \| 29 \| } \| 30 \| \| 31 \| public typealias EventLogger = (identifier: String, event: String, fileName: String, functionName: String, lineNumber: Int) -> () |
| `k00230` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:56:22: error: attribute can only be applied to types, not declarations \| 54 \|  /// \| 55 \|  /// Returns the old value. \| 56 \|  public func modify(@noescape action: (Value) throws -> Value) rethrows -> Value { |
| `k00231` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:28:26: error: single argument function types require parentheses \| 26 \|  case Interrupted \| 27 \| \| 28 \|  public typealias Sink = Event -> () |
| `k00232` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:31:27: error: single argument function types require parentheses \| 29 \|  /// if a terminating event is sent to the observer. The Signal itself will \| 30 \|  /// remain alive until the observer is released. \| 31 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00233` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:31:27: error: single argument function types require parentheses \| 29 \|  /// if a terminating event is sent to the observer. The Signal itself will \| 30 \|  /// remain alive until the observer is released. \| 31 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00235` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:9:30: error: single argument function types require parentheses \| 7 \| /// times concurrently will return an error. \| 8 \| public final class Action<Input, Output, Error: ErrorType> { \| 9 \|  private let executeClosure: Input -> SignalProducer<Output, Error> |
| `k00238` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:570:58: error: single argument function types require parentheses \| 568 \| \| 569 \|      var counter = 0 \| 570 \|      let transform = { (signal: Signal<Int, NoError>) -> Signal<Int, NoError> -> Signal<(Int, Int), NoError> in |
| `k00239` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:37:27: error: single argument function types require parentheses \| 35 \|  /// observer, at which point the disposable returned from the closure will \| 36 \|  /// be disposed as well. \| 37 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00240` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:29:27: error: single argument function types require parentheses \| 27 \|  /// observer, at which point the disposable returned from the closure will \| 28 \|  /// be disposed as well. \| 29 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00241` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:563:58: error: single argument function types require parentheses \| 561 \| \| 562 \|      var counter = 0 \| 563 \|      let transform = { (signal: Signal<Int, NoError>) -> Signal<Int, NoError> -> Signal<(Int, Int), NoError> in |
| `k00242` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:29:27: error: single argument function types require parentheses \| 27 \|  /// observer, at which point the disposable returned from the closure will \| 28 \|  /// be disposed as well. \| 29 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00243` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:65:30: error: 'where' clause next to generic parameters is obsolete, must be written following the declaration's type \| 63 \|  /// Creates a producer for a Signal that will immediately send the values \| 64 \|  /// from the given sequence, then complete. \| 65 \|  public init<S: SequenceType where S.Generator.Element == T>(values: S) { |
| `k00244` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:29:27: error: single argument function types require parentheses \| 27 \|  /// observer, at which point the disposable returned from the closure will \| 28 \|  /// be disposed as well. \| 29 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00245` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:230:28: error: single argument function types require parentheses \| 228 \|   describe("concat") { \| 229 \|    describe("sequencing") { \| 230 \|     var completePrevious: (Void -> Void)! |
| `k00246` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:66:30: error: 'where' clause next to generic parameters is obsolete, must be written following the declaration's type \| 64 \|  /// Creates a producer for a Signal that will immediately send the values \| 65 \|  /// from the given sequence, then complete. \| 66 \|  public init<S: SequenceType where S.Generator.Element == T>(values: S) { |
| `k00247` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:230:28: error: single argument function types require parentheses \| 228 \|   describe("concat") { \| 229 \|    describe("sequencing") { \| 230 \|     var completePrevious: (Void -> Void)! |
| `k00248` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:230:28: error: single argument function types require parentheses \| 228 \|   describe("concat") { \| 229 \|    describe("sequencing") { \| 230 \|     var completePrevious: (Void -> Void)! |
| `k00249` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:230:28: error: single argument function types require parentheses \| 228 \|   describe("concat") { \| 229 \|    describe("sequencing") { \| 230 \|     var completePrevious: (Void -> Void)! |
| `k00250` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:162:28: error: single argument function types require parentheses \| 160 \|   describe("concat") { \| 161 \|    describe("sequencing") { \| 162 \|     var completePrevious: (Void -> Void)! |
| `k00252` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:29:27: error: single argument function types require parentheses \| 27 \|  /// sent, or until the signal's `disposable` has been disposed, at which \| 28 \|  /// point the disposable returned from the closure will be disposed as well. \| 29 \|  public init(_ generator: Observer -> Disposable?) { |
| `k00253` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:92:58: error: single argument function types require parentheses \| 90 \|  /// evidence - Used to prove to the typechecker that the receiver is \| 91 \|  ///            a signal of objects. Simply pass in the `identity` function. \| 92 \|  public func asDeferredRACSignal<U: AnyObject>(evidence: ColdSignal -> ColdSignal<U?>) -> RACSignal { |
| `k00254` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:69:41: error: single argument function types require parentheses \| 67 \|  /// \| 68 \|  /// Returns the disposable which was given to the closure. \| 69 \|  public func startWithSink(sinkCreator: Disposable -> SinkOf<Element>) -> Disposable { |
| `k00255` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:41:24: error: single argument function types require parentheses \| 39 \| \| 40 \|  /// Lifts the given function over the event's value. \| 41 \|  public func map<U>(f: T -> U) -> Event<U> { |
| `k00256` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:28:27: error: single argument function types require parentheses \| 26 \|  /// Initializes a signal that will immediately perform the given action to \| 27 \|  /// begin generating its values. \| 28 \|  public init(_ generator: SinkOf<T> -> Disposable?, file: String = __FILE__, line: Int = __LINE__, function: String = __FUNCTION__) { |
| `k00257` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:18:31: error: single argument function types require parentheses \| 16 \| /// of Events, or even a different version of events altogether. \| 17 \| public struct Producer<T> { \| 18 \|  private let producerClosure: Consumer<T> -> () |
| `k00258` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:109:58: error: single argument function types require parentheses \| 107 \|  /// evidence - Used to prove to the typechecker that the receiver is \| 108 \|  ///            a producer of objects. Simply pass in the `identity` function. \| 109 \|  public func asDeferredRACSignal<U: AnyObject>(evidence: Producer<T> -> Producer<U?>) -> RACSignal { |
| `k00259` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:165:35: error: closure cannot have keyword arguments \| 163 \| \| 164 \|   set(d) { \| 165 \|    let oldState = state.modify { (var state) in |
| `k00260` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:16:24: error: single argument function types require parentheses \| 14 \| /// of Events, or even a different version of events altogether. \| 15 \| public struct Producer<T> { \| 16 \|  private let _produce: Consumer<T> -> () |
| `k00311` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:6:35: error: 'where' clause next to generic parameters is obsolete, must be written following the declaration's type \| 4 \|     public init() { } \| 5 \| \| 6 \|     public init<Cookies: Sequence where Cookies.Iterator.Element == Cookie>(cookies: Cookies) { |
| `k00321` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:28:44: error: expected ',' joining parts of a multi-clause condition \| 26 \|         } \| 27 \| \| 28 \|         while let byte = try buffer.next() where byte != HTTPParser.newLine { |
| `k00327` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:212:47: error: expected ',' joining parts of a multi-clause condition \| 210 \|             self = true \| 211 \|         default: \| 212 \|             if let int = Int(String(cleaned)) where int > 0 { |
| `k00328` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:21:22: warning: extraneous duplicate parameter name; 'line' already has an argument label \| 19 \| \| 20 \| extension SocketIO { \| 21 \|     func writeHeader(line line: String) throws { |
| `k00331` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:140:40: error: attribute can only be applied to types, not declarations \| 138 \|         without repeating yourself. \| 139 \|     */ \| 140 \|     public func group(prefix: String, @noescape handler: () -> Void) { |
| `k00334` | `swift` | 3 | 3 | 0 | Merged output failed syntax check (swiftc -parse) and was suppressed to prevent file corruption: <temp>:150:22: error: single argument function types require parentheses \| 148 \| extension Server: ServerDriverDelegate { \| 149 \|     public func serverDriverDidReceiveRequest(request: Request) -> Response { \| 150 \|         var handler: Request -> Response |

## 4. 验收第 8 行：CRLF 冲突文件与固定用例 36

- CRLF 冲突用例总数：10；`caller` 退出 1 且与 `git` 逐字节相同：10；`eval-python-first` 退出 1 且与 `git` 逐字节相同：10；退出 4 个数：0；不符个数：0。

| 用例 | 语言 | `kind` | `caller` 退出码 | `evalpy` 退出码 | 与 `git merge-file -p` 逐字节相同 |
|---|---|---|---:|---:|---|
| `c00114` | `python` | `conflict` | 1 | 1 | 是 |
| `c00356` | `python` | `conflict` | 1 | 1 | 是 |
| `c00989` | `typescript` | `conflict` | 1 | 1 | 是 |
| `c00992` | `typescript` | `conflict` | 1 | 1 | 是 |
| `c00997` | `typescript` | `conflict` | 1 | 1 | 是 |
| `c01384` | `typescript` | `conflict` | 1 | 1 | 是 |
| `c01387` | `typescript` | `conflict` | 1 | 1 | 是 |
| `c01388` | `typescript` | `conflict` | 1 | 1 | 是 |
| `c01389` | `typescript` | `conflict` | 1 | 1 | 是 |
| `merge-cases/36-py-crlf-true-conflict` | `python` | `fixed` | 1 | 1 | 是 |

## 5. 验收第 9 行：声明级引擎（`ThreeWaySemanticASTMerger`）

### 5.1 冲突集

| 语言 | 总数 | 排除 | 分母 | 相同（`same`） | 相同占比 | 干净但不同 | 副计数：`ws_equal` | 副计数：`human_eq` 左/右 | 仍报冲突 | 拒绝 | 输出损坏 | 超时 |
|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| `python` | 356 | 26 | 330 | 0 | 0.00% | 26 | 4 | 0 / 1 | 253 | 0 | 51 | 0 |
| `swift` | 476 | 99 | 377 | 2 | 0.53% | 62 | 11 | 11 / 7 | 264 | 0 | 49 | 0 |
| `typescript` | 622 | 11 | 611 | 5 | 0.82% | 61 | 2 | 12 / 3 | 343 | 0 | 202 | 0 |
| `all` | 1454 | 136 | 1318 | 7 | 0.53% | 149 | 17 | 23 / 11 | 860 | 0 | 302 | 0 |

### 5.2 干净回归集与单文件耗时

| 语言 | 总数 | 排除 | 分母 | 与 `git` 相同 | 能解析但不同 | 副计数：`ws_equal` | 输出损坏 | 误报冲突 | 超时 | 执行数 | 中位耗时（ms） | 最大耗时（ms） |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `python` | 167 | 17 | 150 | 0 | 32 | 1 | 67 | 51 | 0 | 523 | 62.603 | 1799.925 |
| `swift` | 167 | 40 | 127 | 10 | 51 | 6 | 28 | 38 | 0 | 643 | 48.928 | 1966.199 |
| `typescript` | 166 | 0 | 166 | 3 | 10 | 1 | 98 | 55 | 0 | 788 | 54.559 | 562.453 |
| `all` | 500 | 57 | 443 | 13 | 93 | 8 | 193 | 144 | 0 | 1954 | 55.172 | 1966.199 |

## 6. 验收第 10 行：对照工具 `mergiraf`（跳过数、耗时中位数与最大值）

### 6.1 冲突集

| 语言 | 总数 | 排除 | 分母 | 跳过（总计 / 分母内） | 相同（`same`） | 相同占比 | 干净但不同 | 副计数：`ws_equal` | 副计数：`human_eq` 左/右 | 仍报冲突 | 拒绝 | 输出损坏 | 超时 |
|---|---:|---:|---:|---|---:|---:|---:|---:|---|---:|---:|---:|---:|
| `python` | 356 | 26 | 330 | 0 / 0 | 63 | 19.09% | 58 | 16 | 3 / 1 | 209 | 0 | 0 | 0 |
| `swift` | 476 | 99 | 377 | 476 / 377 | 0 | — | 0 | 0 | 0 / 0 | 0 | 0 | 0 | 0 |
| `typescript` | 622 | 11 | 611 | 0 / 0 | 139 | 22.75% | 197 | 22 | 24 / 4 | 275 | 0 | 0 | 0 |
| `all` | 1454 | 136 | 1318 | 476 / 377 | 202 | 15.33% | 255 | 38 | 27 / 5 | 484 | 0 | 0 | 0 |

### 6.2 干净回归集与单文件耗时（含跳过个数、中位数与最大值）

| 语言 | 干净集总数 | 干净集分母 | 干净集跳过（总/分母） | 与 `git` 相同 | 能解析但不同 | 副计数：`ws_equal` | 输出损坏 | 误报冲突 | 语料总用例 | 语料总跳过 | 实际执行数 | 单文件中位耗时（ms） | 单文件最大耗时（ms） |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `python` | 167 | 150 | 0 / 0 | 148 | 1 | 0 | 0 | 1 | 523 | 0 | 523 | 61.072 | 1987.476 |
| `swift` | 167 | 127 | 167 / 127 | 0 | 0 | 0 | 0 | 0 | 643 | 643 | 0 | 0.000 | 0.000 |
| `typescript` | 166 | 166 | 0 / 0 | 164 | 1 | 1 | 0 | 1 | 788 | 0 | 788 | 69.067 | 3284.415 |
| `all` | 500 | 443 | 167 / 127 | 312 | 2 | 1 | 0 | 2 | 1954 | 643 | 1311 | 66.096 | 3284.415 |

## 7. 验收第 11 行：两种 PATH 下发布的命令结果不同的文件

- 差异文件总数：2（冲突集 0 例，干净集 2 例）。

| 用例 | `kind` | 语言 | `caller`（退出码 / 类别） | `eval-python-first`（退出码 / 类别） | `caller` 原因 |
|---|---|---|---|---|---|
| `k00005` | `clean` | `python` | `3` / `rejected` | `0` / `same` | "Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File ""<temp>"", line 1694 \| match state: \| ^ \| SyntaxError: invalid syntax" |
| `k00161` | `clean` | `python` | `3` / `rejected` | `0` / `same` | "Merged output failed syntax check (python3 -m py_compile) and was suppressed to prevent file corruption: File ""<temp>"", line 143 \| except ipapi.TryNext, exc: \| ^ \| SyntaxError: invalid syntax" |

## 8. 验收第 12 行：固定用例三列汇总与明细

- 固定用例总数：40（`merge-cases` 36 组，`syntax-gate-cases` 4 组中退出 3 为 4 组）。

| 工具 | 总数 | 相同（`same`） | 干净但不同 | 副计数：`ws_equal` | 仍报冲突 | 拒绝（退出 3/4） | 输出损坏 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `git` | 40 | 15 | 0 | 0 | 21 | 0 | 4 |
| `published_caller` | 40 | 23 | 0 | 0 | 13 | 4 | 0 |
| `engine` | 40 | 7 | 15 | 6 | 14 | 0 | 4 |

| 用例 | 语言 | `git` | 发布的命令（`cli`） | 声明级引擎（`engine`） | `cli` 退出码 | `cli` 原因 |
|---|---|---|---|---|---:|---|
| `merge-cases/01-swift-samefunc-difflines` | `swift` | `same` | `same` | `conflict` | 0 |  |
| `merge-cases/02-swift-both-add-func` | `swift` | `conflict` | `same` | `same` | 0 |  |
| `merge-cases/03-swift-rename-vs-body` | `swift` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/04-swift-string-braces` | `swift` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/05-ts-samefunc-difflines` | `typescript` | `same` | `same` | `conflict` | 0 |  |
| `merge-cases/06-ts-both-add-func` | `typescript` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/07-py-samefunc-difflines` | `python` | `same` | `same` | `conflict` | 0 |  |
| `merge-cases/08-py-class-both-add-method` | `python` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/09-py-triplequote` | `python` | `same` | `same` | `damaged` | 0 |  |
| `merge-cases/10-py-rename-vs-body` | `python` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/11-ts-rename-vs-body` | `typescript` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/12-swift-true-conflict` | `swift` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/13-swift-control-nobrace-strings` | `swift` | `conflict` | `same` | `clean_different` | 0 |  |
| `merge-cases/14-py-control-triplequote-nodef` | `python` | `same` | `same` | `damaged` | 0 |  |
| `merge-cases/15-py-class-plain-twomethods` | `python` | `same` | `same` | `conflict` | 0 |  |
| `merge-cases/16-swift-struct-twomethods` | `swift` | `same` | `same` | `same` | 0 |  |
| `merge-cases/17-ts-class-twomethods` | `typescript` | `same` | `same` | `same` | 0 |  |
| `merge-cases/18-ts-control-nobrace` | `typescript` | `conflict` | `same` | `same` | 0 |  |
| `merge-cases/19-py-both-add-toplevel` | `python` | `conflict` | `same` | `clean_different` | 0 |  |
| `merge-cases/20-py-decorator-added` | `python` | `same` | `same` | `clean_different` | 0 |  |
| `merge-cases/21-swift-attribute-and-multiline-string` | `swift` | `same` | `same` | `clean_different` | 0 |  |
| `merge-cases/22-py-nested-indent-decorators` | `python` | `same` | `same` | `conflict` | 0 |  |
| `merge-cases/23-py-both-add-decorated-func` | `python` | `conflict` | `same` | `clean_different` | 0 |  |
| `merge-cases/24-py-decorator-vs-insert-above` | `python` | `conflict` | `conflict` | `clean_different` | 1 |  |
| `merge-cases/25-swift-attr-members-multiline-string` | `swift` | `conflict` | `same` | `same` | 0 |  |
| `merge-cases/26-ts-template-literal-edit-vs-add` | `typescript` | `same` | `same` | `same` | 0 |  |
| `merge-cases/27-js-class-both-add-method-jsdoc` | `javascript` | `conflict` | `same` | `same` | 0 |  |
| `merge-cases/28-rs-attributes-git-clean` | `rust` | `same` | `same` | `clean_different` | 0 |  |
| `merge-cases/29-rs-both-add-fn` | `rust` | `conflict` | `conflict` | `clean_different` | 1 |  |
| `merge-cases/30-go-both-add-func` | `go` | `conflict` | `conflict` | `clean_different` | 1 |  |
| `merge-cases/31-java-annotation-git-clean` | `java` | `same` | `same` | `clean_different` | 0 |  |
| `merge-cases/32-py-modify-vs-adjacent-insert` | `python` | `conflict` | `conflict` | `conflict` | 1 |  |
| `merge-cases/33-swift-no-final-newline-both-add` | `swift` | `conflict` | `same` | `clean_different` | 0 |  |
| `merge-cases/34-py-crlf-git-clean` | `python` | `same` | `same` | `clean_different` | 0 |  |
| `merge-cases/35-py-rst-underline-both-add` | `python` | `conflict` | `conflict` | `damaged` | 1 |  |
| `merge-cases/36-py-crlf-true-conflict` | `python` | `conflict` | `conflict` | `conflict` | 1 |  |
| `syntax-gate-cases/javascript-block-comment` | `javascript` | `damaged` | `rejected` | `clean_different` | 3 | exit=3: syntax_check_failed (node --check) |
| `syntax-gate-cases/python-string-delimiters` | `python` | `damaged` | `rejected` | `clean_different` | 3 | exit=3: syntax_check_failed (python3 -m py_compile) |
| `syntax-gate-cases/swift-string-delimiters` | `swift` | `damaged` | `rejected` | `damaged` | 3 | exit=3: syntax_check_failed (swiftc -parse) |
| `syntax-gate-cases/typescript-block-comment` | `typescript` | `damaged` | `rejected` | `clean_different` | 3 | exit=3: syntax_check_failed (node stripTypeScriptTypes) |

## 去留结论

分母定义：每种语言分别计算，分母为去重后人工版本能被固定解析器读的冲突文件，“相同”只计逐字节相同（三种语言均达到或超过 20% 才算过线）。

### 规则第 1 行“退出 0 却丢了一边新增的行” `difflib` 检查结果与实例

- 冲突集上发布的命令退出 0 的文件数：`caller` 3 例（丢行文件 0 例，丢行总数 0 行），`eval-python-first` 3 例（丢行文件 0 例，丢行总数 0 行）。

| 工具 / PATH | 用例 | 语言 | 分类结果 | `base→left` 新增行数 | `base→right` 新增行数 | 输出缺失的新增行数 | 两边新增行是否全部保留 |
|---|---|---|---|---:|---:|---:|---|
| `published_caller` | `c00006` | `python` | `same` | 51 | 59 | 0 | 是 |
| `published_evalpy` | `c00006` | `python` | `same` | 51 | 59 | 0 | 是 |
| `published_caller` | `c00150` | `python` | `clean_different` | 25 | 9 | 0 | 是 |
| `published_evalpy` | `c00150` | `python` | `clean_different` | 25 | 9 | 0 | 是 |
| `published_caller` | `c00544` | `swift` | `clean_different` | 14 | 10 | 0 | 是 |
| `published_evalpy` | `c00544` | `swift` | `clean_different` | 14 | 10 | 0 | 是 |

### 去留规则逐行对照表（验收第 16 行）

| 行号 | 去留规则条件 | 判定结果 | Python | Swift | TypeScript |
|---:|---|---|---|---|---|
| 1 | 发布的命令有任何一例“输出损坏”，或者退出 0 却丢了一边新增的行 | **没触发** | 损坏 0，退出 0 共 2 例中丢行 0 | 损坏 0，退出 0 共 1 例中丢行 0 | 损坏 0，退出 0 共 0 例中丢行 0 |
| 2 | 发布的命令“与人工相同”在任一语言里不到该语言冲突文件的 20%（暂定） | **触发** | 1 / 330 (0.30%，不到 20%) | 0 / 377 (0.00%，不到 20%) | 0 / 611 (0.00%，不到 20%) |
| 3 | mergiraf 在三种语言上“相同”都不低于发布的命令，且“输出损坏”为 0 | **没触发** | mergiraf 63 / 330 (19.09%) 对发布命令 1 / 330 (0.30%)，损坏 0 | 没跑（不支持 swift，跳过 377 / 377） | mergiraf 139 / 611 (22.75%) 对发布命令 0 / 611 (0.00%)，损坏 0 |
| 4 | 发布的命令在三种语言上都过线，且 mergiraf 不比它好 | **没触发** | 1 / 330 (0.30%，未过线) | 0 / 377 (0.00%，未过线) | 0 / 611 (0.00%，未过线) |
| 5 | 声明级引擎（不论结果都不再单独输出；数字只用来回答“换解析器值不值得”） | **触发** | 相同 0 / 330 (0.00%)，损坏 51 | 相同 2 / 377 (0.53%)，损坏 49 | 相同 5 / 611 (0.82%)，损坏 202 |

注：`mergiraf 0.20.0` 不支持 Swift（Swift 用例在运行阶段计数后跳过，表中记“没跑”）。本节仅列出各项去留规则的触发状态与实测数字，最终去留决定由用户作出。
