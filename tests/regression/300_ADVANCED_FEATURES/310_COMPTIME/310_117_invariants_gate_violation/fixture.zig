// Fixture the declared check counts. Three counted while loops; the
// declaration's ceiling is two.
fn a(len: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < len) : (i += 1) {
        n += i;
    }
    var j: usize = 0;
    while (j < len) : (j += 1) {
        n += j;
    }
    var k: usize = 0;
    while (k < len) : (k += 1) {
        n += k;
    }
    return n;
}
