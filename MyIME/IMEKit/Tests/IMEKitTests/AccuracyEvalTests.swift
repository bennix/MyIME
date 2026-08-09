import Foundation
import Testing
@testable import IMEKit

/// Offline quality benchmark against the bundled system dictionary.
/// Each category asserts a minimum accuracy so regressions in ranking,
/// sentence composition, abbreviation or typo tolerance fail loudly,
/// while individual flaky words don't break the build.
@Suite("AccuracyEval", .serialized) struct AccuracyEvalTests {
    private static let sentencesTop1: [(String, String)] = [
        ("jintiantianqihenhao", "今天天气很好"),
        ("womenmingtianyiqichifan", "我们明天一起吃饭"),
        ("xianzaijidianle", "现在几点了"),
        ("woyijingdaojiale", "我已经到家了"),
        ("zhegewentihenzhongyao", "这个问题很重要"),
        ("xiexienidebangzhu", "谢谢你的帮助"),
        ("zhunishengrikuaile", "祝你生日快乐"),
        ("mingtianzaoshangkaihui", "明天早上开会"),
        ("woxianzaihenmang", "我现在很忙"),
        ("nichifanlema", "你吃饭了吗"),
        ("wanshangyiqikandianying", "晚上一起看电影"),
        ("jintianwanshangchishenme", "今天晚上吃什么"),
        ("womenshenmeshihouchufa", "我们什么时候出发"),
        ("nimingtianyoukongma", "你明天有空吗"),
        ("woganggangxiaban", "我刚刚下班"),
        ("huochezhanzenmezou", "火车站怎么走"),
        ("mashangjiudao", "马上就到"),
        ("wozhengzaikaihui", "我正在开会"),
        ("nizaiganshenme", "你在干什么"),
        ("haojiubujian", "好久不见"),
        ("zhegezhoumoyoushenmeanpai", "这个周末有什么安排"),
        ("mingtianhuixiayuma", "明天会下雨吗"),
        ("wodeshoujimeidianle", "我的手机没电了"),
        ("nixiangchishenme", "你想吃什么"),
        ("womenzaishangbandelushang", "我们在上班的路上"),
        ("zhejiacantinghenhaochi", "这家餐厅很好吃"),
        ("wojintianyoudianlei", "我今天有点累"),
        ("nishenmeshihouxiaban", "你什么时候下班"),
        ("zhouyiwoyaochuchai", "周一我要出差"),
        ("bangwokanyixiazhegewenjian", "帮我看一下这个文件"),
    ]

    private static let wordsTop1: [(String, String)] = [
        ("nihao", "你好"), ("xiexie", "谢谢"), ("zaijian", "再见"),
        ("pengyou", "朋友"), ("shijian", "时间"), ("gongzuo", "工作"),
        ("xuexi", "学习"), ("kaixin", "开心"), ("shouji", "手机"),
        ("diannao", "电脑"), ("wenti", "问题"), ("bangzhu", "帮助"),
        ("xihuan", "喜欢"), ("zhidao", "知道"), ("juede", "觉得"),
        ("keyi", "可以"), ("xianzai", "现在"), ("mingtian", "明天"),
        ("zuotian", "昨天"), ("weishenme", "为什么"), ("zenmeyang", "怎么样"),
        ("dianying", "电影"), ("yinyue", "音乐"), ("yiyuan", "医院"),
        ("xuexiao", "学校"), ("laoshi", "老师"), ("tongshi", "同时"),
        ("huiyi", "会议"), ("lvxing", "旅行"), ("chifan", "吃饭"),
        ("shuijiao", "睡觉"), ("xiawu", "下午"), ("shangban", "上班"),
        ("xiaban", "下班"), ("kafei", "咖啡"), ("pijiu", "啤酒"),
        ("dianhua", "电话"), ("youxi", "游戏"), ("shengri", "生日"),
        ("zhoumo", "周末"),
    ]

    private static let wordsTop3: [(String, String)] = [
        ("yisi", "意思"), ("shiji", "实际"), ("jiaoyu", "教育"),
        ("xiaoguo", "效果"), ("yijian", "意见"), ("gongsi", "公司"),
        ("kaishi", "开始"), ("xingqi", "星期"), ("banfa", "办法"),
        ("qingkuang", "情况"), ("jihua", "计划"), ("fangbian", "方便"),
        ("anpai", "安排"), ("zhunbei", "准备"), ("liaojie", "了解"),
        ("jieshu", "结束"), ("canjia", "参加"), ("tongyi", "同意"),
        ("queren", "确认"), ("fasong", "发送"), ("tongshi", "同事"),
    ]

    private static let abbreviationsTop5: [(String, String)] = [
        ("bj", "北京"), ("sh", "上海"), ("nh", "你好"),
        ("sj", "手机"), ("xx", "学习"), ("gz", "工作"),
        ("wt", "问题"), ("pengy", "朋友"), ("xiex", "谢谢"),
        ("mingt", "明天"),
    ]

    private static let typosTop3: [(String, String)] = [
        ("nihoa", "你好"),
        ("zhognguo", "中国"),
        ("jintain", "今天"),
        ("shijei", "世界"),
        ("xeixie", "谢谢"),
        ("migntian", "明天"),
    ]

    private static let trailingPartialTop3: [(String, String)] = [
        ("jintiantianq", "今天天气"),
        ("mingtianzaosh", "明天早上"),
        ("woxianzaihenm", "我现在很忙"),
        ("xiexienidebangz", "谢谢你的帮助"),
    ]

    private static func bundledStore() throws -> SQLiteStore {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let databasePath = ProcessInfo.processInfo.environment["MYIME_TEST_SYSTEM_DATABASE"]
            ?? packageDirectory.appending(path: "../MyIME/Resources/system.sqlite").standardizedFileURL.path
        return try #require(SQLiteStore(path: databasePath))
    }

    private static func measure(
        _ cases: [(String, String)],
        topK: Int,
        engine: Engine,
        label: String
    ) -> Double {
        var hits = 0
        var misses: [String] = []
        for (input, expected) in cases {
            let words = engine.update(input, prefs: EnginePrefs()).candidates.prefix(topK).map(\.word)
            if words.contains(expected) {
                hits += 1
            } else {
                misses.append("\(input) → 期望 \(expected), 实得 \(words.prefix(3).joined(separator: "/"))")
            }
        }
        let accuracy = Double(hits) / Double(max(1, cases.count))
        print("EVAL[\(label)] top\(topK): \(hits)/\(cases.count) = \(String(format: "%.1f%%", accuracy * 100))")
        for miss in misses { print("  MISS \(miss)") }
        return accuracy
    }

    @Test func benchmarkAgainstBundledDictionary() throws {
        let engine = Engine(store: try Self.bundledStore())
        let sentence = Self.measure(Self.sentencesTop1, topK: 1, engine: engine, label: "整句")
        let word1 = Self.measure(Self.wordsTop1, topK: 1, engine: engine, label: "常用词")
        let word3 = Self.measure(Self.wordsTop3, topK: 3, engine: engine, label: "多义词")
        let abbreviation = Self.measure(Self.abbreviationsTop5, topK: 5, engine: engine, label: "简拼")
        let typo = Self.measure(Self.typosTop3, topK: 3, engine: engine, label: "错拼")
        let partial = Self.measure(Self.trailingPartialTop3, topK: 3, engine: engine, label: "尾部简拼")

        #expect(sentence >= 0.96)
        #expect(word1 >= 0.95)
        #expect(word3 >= 0.95)
        #expect(abbreviation >= 0.90)
        #expect(typo >= 0.80)
        #expect(partial >= 0.75)
    }
}
