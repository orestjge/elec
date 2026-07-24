/// エッヂ (eddist) / 5ch 互換掲示板のプロトコルロジック。
///
/// dat / subject.txt のパースと Range 差分取得。HTTP は [HttpFetcher] で
/// 抽象化してあり、この層はネットワークにも Flutter にも依存しない。
library;

export 'src/board_url.dart';
export 'src/dat_fetch.dart';
export 'src/dat_parser.dart';
export 'src/html_text.dart';
export 'src/http.dart';
export 'src/metrics.dart';
export 'src/models.dart';
export 'src/replies.dart';
export 'src/setting_txt.dart';
export 'src/subject_fetch.dart';
export 'src/subject_parser.dart';
export 'src/thread_url.dart';
export 'src/write.dart';
