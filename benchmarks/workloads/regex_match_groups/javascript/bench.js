const n = parseInt(process.argv[2] || "3000000", 10);

// Named capture groups, anchored full-match.
const re = /^(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)$/;
const inputs = ["2x3x4", "20x3x11", "hello world!"];

let matched = 0, none = 0, total = 0;
for (let i = 0; i < n; i++) {
    const s = inputs[i % 3];
    const m = re.exec(s);
    if (m) {
        const l = +m.groups.l, w = +m.groups.w, h = +m.groups.h;
        total += l * w * h;
        matched++;
    } else {
        none++;
    }
}
console.log(`matched = ${matched} none = ${none} total = ${total}`);
