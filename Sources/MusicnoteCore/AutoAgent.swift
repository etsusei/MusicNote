import Foundation

/// Model-driven analysis: the model reads evidence through tools, decides what to check next,
/// reviews doubtful spots, and submits a bar-by-bar harmony. The operating manual below is a
/// default way of working, not a fixed pipeline.
public enum AutoAgent {
    public static let defaultMaxToolCalls = 28
    public static let defaultMaxSeconds = 900.0

    public static let manual = """
    你是 Musicnote 的和声分析员。用户已经选好原曲的一段区间，你要通过调用工具自己取证、比较、复核，最后用 submit_analysis
    交付：按小节的和弦走向（每个和弦在第几小节第几拍）、哪些是经过/连接/替代/色彩和弦、以及少量需要用户亲耳确认的位置。
    不是解释别人算好的结果：程序给的草稿和 Logic 的候选都只是参考，结论由你根据证据决定。

    证据和它们的局限：
    - Logic Chord ID（run_logic_chords）：直接读音频的候选和边界。不是真值，可能漏掉短和弦、分段不当；词表没有 9/11/13 等扩展音。
    - MuScriptor 与 MT3 两路转录（run_transcription）：音符证据。所选分轨（钢琴、吉他或“其他”）已经分离过，转录保留其中全部有音高的乐器
      （和弦可能在合成器、吉他上），原曲来源只去掉鼓和人声。两者一致只说明这个音存在，不说明它属于和弦；
      单边出现的音可能是漏转也可能是误转。align_transcriptions 给出对齐结果。
    - 人工校对 MIDI（若有）：用户亲手改过，是最可靠的音符证据。
    - 已保存和声里标“人工命名”的和弦是用户确认过的，除非证据明确矛盾不要改；有分歧就放进 toConfirm 让用户判断。
    - local_audio_check：某个窗口的音频音级能量和三路音符明细，用来复核具体的音。谐波会抬高五度、八度的能量，不能直接当作实际按下的音。

    默认做法（常见情况照着走就够了；可以跳过、调换或回头再做，已有的有效结果直接复用，不要用同样参数重复调用）：
    1. inspect_analysis：看选区、速度网格、小节线、已有的证据和人工数据。
    2. run_logic_chords（原曲，四分拍点）拿到基础候选。
    3. 没有转录结果时对所选分轨（source=stem）各跑一次 MT3 和 MuScriptor，再 align_transcriptions。
    3.5 小节线核对：拿到 Logic 和转录后调用一次 check_bar_lines。用户的小节线可能放错了（整曲拍点检测在切分节奏、前奏里常锁错），
       如果换和弦点和低音换音大多落在第 3 拍或反拍上，说明网格偏了：不要把每个和弦都写成从第 3 拍开始、跨小节延续，
       而是照常按现在网格写位置，并在 submit 的 barLine 里给出 shiftBeats 和理由。它还会给出和弦走向的重复周期：
       前后两遍应当一致，一遍里看清楚的经过和弦、换和弦位置可以用来核对另一遍；两遍不一致的地方要么是真的变化，要么值得复核。
    4. 按乐句（每次最多 8 小节）调用 bar_evidence，把各路证据放在一起读。需要时可用 harmony_draft 看程序的分组草稿。
    5. 形成和弦走向：和弦卡在拍子上，通常一个和弦占一小节或半小节；经过和弦只在音确实变了的时候才占四分或八分；
       反拍按下并延续过下一拍的和弦算提前进入；伴奏节奏型反复按同一个和弦只算一个；旋律音不要当成和弦音，也不要简单删掉最高音或短音。
       名字可以带 Logic 没有的扩展音（如 Fm9、A♭maj7(♯11)），也可以新增 Logic 没给出的短和弦。
    6. 疑难复核：只在会影响结论的地方做，比如根音/性质分歧、疑似漏掉的短和弦、决定性质的那个音没有证据、重复乐句解释互相矛盾。
       复核前先用 note_review 写下要分辨的问题和什么新证据会改变结论；复核后再用 note_review 记录观察到的证据、决定和停止原因。
       同样的方法查不出新信息就换证据来源或停止，把仍不确定的位置放进 toConfirm，不要为了“确定”而硬猜。
    7. 调性检查（必做一次）：和弦走向成形后调用 key_check，把你的和弦序列按顺序传进 chords。它并排给出用户设定的调、整段音频音级与大小调模板的吻合度、
       低音分布和和弦调性评分。用户设定的调可能是错的（比如听成了关系大小调），以证据为准；结论和理由写进 submit 的 key，与用户设定不同就说清楚依据。
    8. submit_analysis 提交（结果先等用户采用，再替换当前和声）。之后用一两句中文结束，不要提版本号。

    规则：
    - 只能分析这个选区；工具会拒绝选区外的请求。不要修改用户的 MIDI、笔记和标签（工具也不提供这种能力）。
    - 你没有听到音频，不要说“听起来”“我听到”；可以说“音频音级能量显示”“两路转录都有”。
    - 不要给“95% 正确”这类数字；confidence 只用 high / medium / low。
    - 预算有限（约 \\(defaultMaxToolCalls) 次工具调用）。收到 BUDGET_EXCEEDED 时立刻提交当前最好的结果。

    submit_analysis 的要求：
    - chords 覆盖整个选区，从第 1 小节到最后，按时间顺序；bar 从 1 开始，beat 从 1 开始，后半拍写 .5（如 3.5）。
    - symbol 用常见写法：Fm7、G7、G7/B、C7sus4、A♭maj7、Bdim7、Cm(add9)。
    - role 用 backbone（主干）/ passing（经过）/ connecting（连接）/ substitute（替代）/ color（同一和声的色彩变化）。
      reason 用一句白话说依据（例如“两路转录都有 B 和 F，低音 G，接到 Cm”）。
    - toConfirm 最多 6 处，每处写清楚让用户听什么（例如“第 2 小节第 4 拍：低音是 B 还是 B♭？”）。
    - summary 用一两句话说这段和声在做什么。key 写你判断的调和一句理由（可与用户设定不同）。
    """

    public static func toolSpecs() -> [[String: Any]] {
        func obj(_ props: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": props, "required": required, "additionalProperties": false]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let num: [String: Any] = ["type": "number"]
        let bool: [String: Any] = ["type": "boolean"]
        return [
            ["name": "inspect_analysis", "description": "查看选区、速度网格、小节线、调、已有证据和人工数据、预算。", "inputSchema": obj([:])],
            ["name": "run_logic_chords", "description": "用本机 Logic Pro Chord ID 分析选区音频，得到和弦候选与边界（按小节.拍列出）。已有同参数结果时直接复用。",
             "inputSchema": obj(["source": ["type": "string", "enum": ["original", "stem"], "description": "original=原曲混音，stem=已选分轨（钢琴/吉他/其他）"],
                                 "grid": ["type": "string", "enum": ["quarter", "eighth"]], "refresh": bool])],
            ["name": "run_transcription", "description": "把选区转录成音符。stem（已选分轨）保留全部有音高的乐器，original 去掉鼓和人声。MT3 在 GPU 上约 20 秒，MuScriptor 约 20 秒。已有结果时复用。",
             "inputSchema": obj(["engine": ["type": "string", "enum": ["mt3", "muscriptor"]],
                                 "source": ["type": "string", "enum": ["stem", "original"]], "refresh": bool], ["engine"])],
            ["name": "align_transcriptions", "description": "对齐 MuScriptor 与 MT3 的转录，给出整体偏移、共同/单边音数和每小节一致率。",
             "inputSchema": obj(["source": ["type": "string", "enum": ["stem", "original"]]])],
            ["name": "bar_evidence", "description": "按小节列出各路证据：Logic 候选、已保存和声、人工 MIDI 与双转录在每个八分位置按下的音（标出单边音）。一次最多 8 小节。",
             "inputSchema": obj(["fromBar": int, "toBar": int], ["fromBar", "toBar"])],
            ["name": "local_audio_check", "description": "复核一个窗口：音频音级能量（HPCP）加三路音符明细和 Logic 候选。用于确认具体的音。",
             "inputSchema": obj(["bar": int, "beat": num, "endBar": int, "endBeat": num,
                                 "source": ["type": "string", "enum": ["stem", "original"]]], ["bar", "beat", "endBar", "endBeat"])],
            ["name": "harmony_draft", "description": "程序按拍子分组 + 模板命名的草稿（参考用，可以整体推翻）。",
             "inputSchema": obj(["useUserMidi": bool])],
            ["name": "check_bar_lines", "description": "小节线核对：Logic 换和弦点和低音换音落在小节第几拍、是否该整体挪小节线，以及和弦走向的重复周期。",
             "inputSchema": obj([:])],
            ["name": "key_check", "description": "调性检查：用户设定的调、整段音频音级与大小调模板的吻合度、低音分布、和弦序列的调性评分并排列出。提交前必须调用一次。",
             "inputSchema": obj(["chords": ["type": "array", "items": str, "description": "你得出的和弦序列（按时间顺序），不给则用已保存的和声"]])],
            ["name": "note_review", "description": "记录一次定向复核：要分辨的问题、预期证据、操作、观察到的证据、决定、停止原因。复核前后各记一次即可。",
             "inputSchema": obj(["question": str, "expectedEvidence": str, "operation": str, "observedEvidence": str,
                                 "decision": str, "stopReason": str], ["question"])],
            ["name": "submit_analysis", "description": "提交最终结果（保存为待用户采用的结果；用户采用后才替换当前和声，不改动用户的 MIDI/笔记）。可在同一次分析中重复提交以覆盖。",
             "inputSchema": obj([
                 "summary": str,
                 "key": obj(["tonic": str, "mode": ["type": "string", "enum": ["major", "minor"]], "name": str, "reason": str], ["tonic", "mode", "reason"]),
                 "chords": ["type": "array", "items": obj([
                     "bar": int, "beat": num, "symbol": str,
                     "role": ["type": "string", "enum": ["backbone", "passing", "connecting", "substitute", "color"]],
                     "reason": str, "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                 ], ["bar", "beat", "symbol", "role"])],
                 "toConfirm": ["type": "array", "items": obj(["bar": int, "beat": num, "question": str], ["bar", "beat", "question"])],
                 "barLine": obj(["shiftBeats": ["type": "number", "description": "小节线整体后移的拍数（负数为前移，可为 .5）"], "reason": str], ["shiftBeats", "reason"]),
             ], ["summary", "chords", "key"])],
        ]
    }

    public static func task(songTitle: String, item: AnalysisItem, bars: Int) -> String {
        "请分析《\(songTitle)》\(item.title) 这个选区（原曲 \(formatTime(us: item.trimStartUs))–\(formatTime(us: item.trimEndUs))，共 \(bars) 小节）。"
            + "按操作手册自主取证和复核，最后用 submit_analysis 交付。"
    }

    /// Runs one analysis end to end. Throws only if the model couldn't be reached; a run that
    /// ends without a submission is reported in the run record.
    public static func run(toolbox: AutoToolbox, provider: any AgentProvider, songTitle: String, model: String?, effort: String?,
                           onDelta: @escaping @Sendable (String) -> Void = { _ in }) async {
        do {
            let item = try toolbox.item()
            let bars = try toolbox.bars(item)
            let scratch = toolbox.paths.jobs.appendingPathComponent("auto-\(toolbox.run.id.uuidString)", isDirectory: true)
            let final = try await provider.runAgent(systemPrompt: manual, task: task(songTitle: songTitle, item: item, bars: bars),
                                                    tools: toolSpecs(), model: model, effort: effort, scratchDir: scratch,
                                                    handler: { name, args in await toolbox.call(name, args) }, onDelta: onDelta)
            if !toolbox.run.submitted {
                toolbox.finish(status: .failed, message: final, error: "模型结束时没有提交结果")
            } else {
                toolbox.finish(status: .succeeded, message: final)
            }
        } catch is CancellationError {
            toolbox.finish(status: .cancelled, message: "", error: "已取消")
        } catch {
            toolbox.finish(status: toolbox.run.submitted ? .succeeded : .failed, message: "", error: error.localizedDescription)
        }
    }
}
