/**
 * GB2312 汉字 -> 拼音声母查找表（与 Android 版 PinyinInitials.kt 同一份数据）。
 *
 * 索引：`(b1 - 0xB0) * 94 + (b2 - 0xA1)`，b1/b2 是该字 GB2312 编码的两个字节，
 * 覆盖 GB2312 全部 6763 个汉字；表里空格表示该位置没有读音。
 *
 * 为什么不用第三方拼音库：一张 6.7 KB 的字符串就能覆盖全部常用字，
 * 不引依赖、不联网，冷启动也不会因此变慢。
 *
 * 取码不自己实现编码器：启动时把所有 GB2312 码位拼成一段字节，交给系统的
 * GB18030 解码器一次性解成字符串，再按索引把声母贴上去。整表只解一次。
 */

import { util } from '@kit.ArkTS';

const TABLE: string =
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' +
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbpbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' +
  'bbbbbbbbbbbbbbbbbbbpbbbbbbbbbbbbcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' +
  'ccczccccccccccccccccccccccccccccccccccccccccccccccccccsccccccccccccccccccccccccccccccccccccccc' +
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccddddddddddddddddd' +
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' +
  'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddeeeeeeeeeeeeeeeeeeeee' +
  'efffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' +
  'fffffffffffpffffffffffffffffffffggggggggggggggggggggggggggggggggggggggggggggggggghgggggggggggg' +
  'gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggh' +
  'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh' +
  'hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhjjjjjjjj' +
  'jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjkjjjjjjj' +
  'jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj' +
  'jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj' +
  'jjjjjkkkgkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkg' +
  'kkkkkkkkkkklllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll' +
  'llllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllll' +
  'lllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllllmmmmmmmmmmmmmmmmmmmmmmm' +
  'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm' +
  'mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn' +
  'nnnnnnnnnnnnnnnnnnnnnooooooooppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp' +
  'pppppppppppppppppppppppppppppppppppppppppppppppppppppppppqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' +
  'qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqjqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' +
  'qqqqqqqqqqqqqqqqqgqqqqqqqqrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrsssssssss' +
  'ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss' +
  'ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss' +
  'sssssssssssssssssssssssssssssssssssscssssssssssssssssssssssssssssssssssssssssssssssssssssttttt' +
  'tttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt' +
  'tttttttttttttttttttttttttttttttttttttttttttttttttttttttttwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww' +
  'wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwxxxxxxxxxxx' +
  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxsxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' +
  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxcxxxxxxxxxxx' +
  'xxxxxxxxxxxxxxxxxxxxxxxxyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' +
  'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy' +
  'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyxyyyyyyyyy' +
  'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzczzzzzy' +
  'zzzzzzzzzzzzzzzzzzzzzznzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' +
  'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' +
  'zzzzzzzzzzzzzzzzzzzzczzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz     ' +
  'cjwgnspgcgnegypbtyyzdxykygtzjnmjqmbsgzscyjsyyfpgkbzgydywjkgkljswkpjqhyjwrdzlsgmrypywwcckznkyyg' +
  'ttngjeykkzytcjnmcylqlypyqfqrpzslwbtgkjfyxjwzltbncxjjjjtxdttsqzycdxxhgckbphffsstybgmxlpbyllbhlx' +
  'smzmyjhsojnghdzqyklgjhsgqzhxqgkezzwyscscjxyeyxadzpmdssmzjzqjyzcjjfwqjbdzbxgznzcpwhkxhqkmwfbpby' +
  'dtjzzkqhylygxfptyjyyzpszlfchmqshgmxxsxjyqdcsbbqbefsjyhwwgzkpylqbgldlcctnmayddkssngycsgxlyzaypn' +
  'ptsdkdylhgymylcxpycjndqjwqqxfyyfjlejpzrxccqwqqsbzkymgplbmjrqcflnymyqmsqtrbcjthztqfrxqhxmjjcjlx' +
  'xgjmshzkbswyemyltxfsydsglycjqxsjnqbsctyhbftdcyjdjwyghqfrxwckqkxebptlpxjzsrmebwhjlbjslyysmdxlcl' +
  'qkxlhxjrzjmfqhxhwywsbhtrxxglhqhfnmgykldyxzpylggsmtcfpajjzyljtyanjgbjplqgdzyqyaxbkysecjsznslyzh' +
  'zxlzcghpxzhznytdsbcjkdlzyyfwydlebbgqyzkggldndnyskjshdlyxbcghxypkdjmmzngmmclgwzszxzjfznmlzzthcs' +
  'ydbdllscddnlkjykjsycjlkohqasdknhcsganhdaashtcplcpqybsdmpjlpcjoqlcdhjjysprchnwjnlhlyyqyhwzptczg' +
  'wwmzffjqqqqyxaclbhkdjxdgmmydjxzllsygxgkjrywzwyclzmssjzldbydcpcxyhlxchyzjqsqqagmnyxpfrkssbjlyxy' +
  'syglnscmhcwwmnzjjlxxhchsyzsttxrycyxbyhcsmxjsznpwgpxxtaybgajcxlyxdccwzocwkccsbnhcpdyznfcyytyckx' +
  'kybsqkkytqqxfcwchcykelzqbsqyjqcclmthsywhmktlkjlycxwheqqhtqhqpqsqscfymmdmgbwhwlgsllystlmlxpthmj' +
  'hwljzyhzjxhtxjlhxrswlwzjcbxmhzqxsdzpmgfcsglsxymjshxpjxwmyqksmyplrthbxftpmhyxlchlhlzylxgsssstcl' +
  'sldclrpbhzhxyyfhbmgdmycnqqwlqhjjcywjzyejjdhpblqxtqkwhlchqxagtlxljxmsljhtzkzjecxjcjnmfbycsfywyb' +
  'jzgnysdzsqyrsljpclpwxsdwejbjcbcnaytwgmpapclyqpclzxsbnmsggfnzjjbzsfzyndxhplqkzczwalsbccjxsyzgwk' +
  'ypsgxfzfcdkhjgxtlqfsgdslqwzkxtmhsbgzmjzrglyjbpmlmsxlzjqqhzyjczydjwbwjklddpmjegxyhylxhlqyqhkycw' +
  'cjmyyxnatjhyccxzpcqlbzwwytwbqcmlpmyrjcccxfpznzzljplxxyztzlgdldcklyrzzgqtgjhhgjljaxfgfjzslcfdqz' +
  'lclgjdjzsnzlljpjqdcclcjxmyzftsxgcgsbrzxjqqctzhgyqtjqqlzxjylylbcyamcstylpdjbyregklzyzhlyszqlznw' +
  'czcllwjqjjjkdgjzolbbzppglghtgzxyjhzmycnqcycyhbhgxkamtxyxnbskyzzgjzlqjdfcjxdygjqjjpmgwgjjjpkqsb' +
  'gbmmcjssclpqpdxcdyykypcjddyygywrhjrtgznyqldkljszzgzqzjgdykshpzmtlcpwnjyfyzdjcnmwescyglbtzcgmss' +
  'llyxysxsbsjsbbsgghfjlypmzjnlyywdqshzxtyywhmcyhywdbxbtlmsyyyfsxjcbdxxlhjhfssxzqhfzmzcztqcxzxrtt' +
  'djhnnyzqqmtqdmmgyydxmjgdhcdyzbffallztdltfxmxqzdngwqdbdcdjdxbzgsqqddjcmbkzffxmkdmdsyyszcmljdsyn' +
  'sprskmkmpcklgtbqtfzswtfgglyplljzhgjjgypzltcsmcnbtjbqfkthbyzgkpbbymtdssxtbnpdkleycjnyddykzddhqh' +
  'sdzsctarlltkzlgecllkjlqjaqnbdkkghpjtzqksecshalqfmmgjnlyjbbtmlyzxdcjpldlpcqdhzycbzsczbzmsljflkr' +
  'zjsnfrgjhxpdhyjybzgdlqcsezgxlblgyxtwmabchecmwyjyzlljjyhlgndjlslygkdzpzxjyyzlwcxszfgwyydlyhcljs' +
  'cmbjhblyzlycblydpdqysxqzbytdkyxjyycnrjmpdjgklcljbctbjddbblblczqrppxjcjlzcshltoljnmdddlngkathqh' +
  'jhykheznmshrphqqjchgmfprxhjgdychghlyrzqlcyqjnzsqtkqjymszswlcfqqqxyfggyptqwlmcrnfkkfsyylqbmqamm' +
  'myxctpshcptxxzzsmphpshmclmldqfyqxszyjdjjzzhqpdszglstjbckbxyqzysgpsxqzqzrqtbdkyxzkhhgflbcsmdldg' +
  'dzdblzyycxnncsybzbfglzzxswmsccmqnjqsbdqsjtxxmbltxzclzshzcxrqjgjylxzfjphymzqqydfqjjlzznzjsdgzyg' +
  'ctxmzysctlkphtxhtlbjxjlxscdqxcbbtjfqzfsltjbtkqbxxjjljchczdbzjdczjdcprnpqcjpfczlclzxzdmxmphjsgz' +
  'gszzqjylwtjpfsyaxmcjbtzkycwmytzsjjlqcqlwzmalbxyfbpnlsfhtgjwejjxxglljstgshjqlzfkcgnndszfdeqfhbs' +
  'aqtgylbxmmygszldydqmjjrgbjtkgdhgkblqkbdmbylxwcxyttybkmrtjzxqjbhlmhmjjzmqasldcyxyqdlqcafywyxqhz';

/** GB2312 汉字区：区 0xB0–0xF7，位 0xA1–0xFE */
const ROWS: number = 72;
const COLS: number = 94;

export class PinyinInitials {
  /** 汉字 -> 声母；首次使用时构建 */
  private static map: Map<string, string> | null = null;
  private static broken: boolean = false;

  private static build(): Map<string, string> {
    const map: Map<string, string> = new Map();
    const bytes: Uint8Array = new Uint8Array(ROWS * COLS * 2);
    let k = 0;
    for (let r = 0; r < ROWS; r++) {
      for (let c = 0; c < COLS; c++) {
        bytes[k++] = 0xB0 + r;
        bytes[k++] = 0xA1 + c;
      }
    }
    try {
      const text: string = util.TextDecoder.create('gb18030').decodeToString(bytes);
      const total: number = Math.min(text.length, TABLE.length);
      for (let i = 0; i < total; i++) {
        const ch: string = text.charAt(i);
        const initial: string = TABLE.charAt(i);
        // 码区里未分配的位置解码成替换字符，表里对应空格，跳过
        if (ch === '\uFFFD' || initial === ' ') {
          continue;
        }
        if (!map.has(ch)) {
          map.set(ch, initial);
        }
      }
    } catch (e) {
      PinyinInitials.broken = true;
    }
    return map;
  }

  /** 单个字符的声母；ASCII 字母数字返回自身小写，其他返回空串 */
  static initialOf(ch: string): string {
    if (ch === '') {
      return '';
    }
    if (/^[0-9a-zA-Z]$/.test(ch)) {
      return ch.toLowerCase();
    }
    if (ch.charCodeAt(0) < 0x2E80) {
      return '';
    }
    if (PinyinInitials.map === null) {
      PinyinInitials.map = PinyinInitials.build();
    }
    const hit: string | undefined = PinyinInitials.map.get(ch);
    return hit !== undefined ? hit : '';
  }

  /** 一串文字的拼音首字母：「超级汽车」→ "cjqc"，「超级宝贝JOJO」→ "cjbbjojo" */
  static initialsOf(text: string): string {
    if (text === '') {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < text.length; i++) {
      out += PinyinInitials.initialOf(text.charAt(i));
    }
    return out;
  }

  /** 解码器不可用时联想功能降级，界面上不显示拼音命中 */
  static isAvailable(): boolean {
    if (PinyinInitials.map === null) {
      PinyinInitials.map = PinyinInitials.build();
    }
    return !PinyinInitials.broken;
  }
}
