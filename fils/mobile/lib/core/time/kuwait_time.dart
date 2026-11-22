/// Kuwait reporting-time helpers.
///
/// Asia/Kuwait is UTC+03:00 year-round (Kuwait doesn't observe DST), so a fixed
/// offset is exact. All timestamps are stored in UTC. Reporting periods (days, months
/// and salary cycles) are computed in the user's reporting zone, which defaults to
/// Asia/Kuwait.
library;

class ReportingZone {
  final String name;
  final Duration offset;
  const ReportingZone(this.name, this.offset);
  static const kuwait = ReportingZone('Asia/Kuwait', Duration(hours: 3));

  /// Convert a UTC instant to a "wall clock" DateTime (marked UTC to avoid device-zone
  /// interference) in this zone.
  DateTime toWall(DateTime utc) => utc.toUtc().add(offset);

  /// Convert wall-clock components in this zone to a UTC instant.
  DateTime fromWall(int y, int m, int d, [int hh = 0, int mm = 0, int ss = 0]) =>
      DateTime.utc(y, m, d, hh, mm, ss).subtract(offset);

  /// Start of the wall-clock day containing [utc], returned as a UTC instant.
  DateTime startOfDay(DateTime utc) {
    final w = toWall(utc);
    return fromWall(w.year, w.month, w.day);
  }
}

/// A half-open reporting period [start, end) in UTC.
class Period {
  final DateTime start;
  final DateTime end;
  const Period(this.start, this.end);
  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);
  Duration get length => end.difference(start);
  @override
  String toString() => 'Period($start → $end)';
  @override
  bool operator ==(Object o) => o is Period && o.start == start && o.end == end;
  @override
  int get hashCode => Object.hash(start, end);
}

int _daysInMonth(int y, int m) => DateTime.utc(y, m + 1, 0).day;

/// Salary-cycle calculator. A cycle starts on [startDay] of each month (1–31). If a
/// month is shorter than [startDay], the cycle starts on that month's last day. A
/// start day of 1 is a plain calendar month.
class CycleCalculator {
  final int startDay;
  final ReportingZone zone;
  const CycleCalculator({this.startDay = 1, this.zone = ReportingZone.kuwait})
      : assert(startDay >= 1 && startDay <= 31);

  DateTime _cycleStartWall(int y, int m) {
    final d = startDay > _daysInMonth(y, m) ? _daysInMonth(y, m) : startDay;
    return DateTime.utc(y, m, d);
  }

  /// The cycle containing [utc].
  Period cycleFor(DateTime utc) {
    final w = zone.toWall(utc);
    var y = w.year, m = w.month;
    var s = _cycleStartWall(y, m);
    final wDay = DateTime.utc(w.year, w.month, w.day);
    if (wDay.isBefore(s)) {
      m -= 1;
      if (m == 0) {
        m = 12;
        y -= 1;
      }
      s = _cycleStartWall(y, m);
    }
    var ny = y, nm = m + 1;
    if (nm == 13) {
      nm = 1;
      ny += 1;
    }
    final e = _cycleStartWall(ny, nm);
    return Period(zone.fromWall(s.year, s.month, s.day), zone.fromWall(e.year, e.month, e.day));
  }

  Period previous(Period p) => cycleFor(p.start.subtract(const Duration(seconds: 1)));
  Period next(Period p) => cycleFor(p.end);

  /// Whole days left until the next cycle starts (payday), counted in wall-clock days.
  int daysUntilNext(DateTime nowUtc) {
    final p = cycleFor(nowUtc);
    final today = zone.startOfDay(nowUtc);
    return p.end.difference(today).inHours ~/ 24;
  }
}

/// The calendar month containing [utc] in [zone].
Period calendarMonth(DateTime utc, {ReportingZone zone = ReportingZone.kuwait}) =>
    CycleCalculator(startDay: 1, zone: zone).cycleFor(utc);
