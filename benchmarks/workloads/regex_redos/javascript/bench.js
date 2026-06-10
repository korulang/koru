const n = parseInt(process.argv[2] || "30", 10);

const re = /^(a+)+b$/;
const input = "a".repeat(n);

console.log(`matched = ${re.test(input)} len = ${n}`);
