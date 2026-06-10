const n = parseInt(process.argv[2] || "3000000", 10);

const email = /^[a-z]+@[a-z]+$/;
const number = /^[0-9]+$/;
const inputs = ["foo@bar", "12345", "hello world!"];

let ce = 0, cn = 0, cx = 0;
for (let i = 0; i < n; i++) {
    const s = inputs[i % 3];
    if (email.test(s)) ce++;
    else if (number.test(s)) cn++;
    else cx++;
}
console.log(`email = ${ce} number = ${cn} none = ${cx}`);
