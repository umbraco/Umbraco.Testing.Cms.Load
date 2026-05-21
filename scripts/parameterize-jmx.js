// Convert hardcoded JMeter Arguments to JMeter properties (${__P(name,default)})
// so the harness can pass values at runtime via -Jname=value.
//
// Run once after .jmx files are added/updated to make them harness-compatible.
// Re-runs are idempotent — already-parameterized values are skipped.

const fs = require('fs');
const path = require('path');

// Only parameterize values that the harness needs to override at runtime.
// totalOfMember and member_password ARE overridable because the seeder's
// member count varies by preset (Small=10, Medium=50, Large=…) and the
// member password is configurable via Configuration:Members:DefaultPassword.
// The harness discovers actual values via /umbraco/api/seederstatus/inventory
// at warmup time (see "Discover seeder member state" step in
// templates/load-test-job.yml). MemberLogin.jmx already has these as
// properties — listed here so the parameterize script doesn't strip them.
const OVERRIDABLE = new Set([
    'server',
    'protocol',
    'port',
    'numberOfThread',
    'duration',
    'backoffice_username',
    'backoffice_password',
    'totalOfMember',
    'member_password',
]);

const JMETER_ROOT = path.join(__dirname, '..', 'loadtests', 'scenarios', 'Default', 'jmeter');

function parameterizeFile(filepath) {
    let content = fs.readFileSync(filepath, 'utf8');
    let changes = 0;
    const before = content;

    // Match an Argument elementProp block — name comes first, then value.
    // The block has this shape (whitespace varies but the order is stable):
    //   <elementProp name="X" elementType="Argument">
    //     <stringProp name="Argument.name">X</stringProp>
    //     <stringProp name="Argument.value">CURRENT</stringProp>
    const regex = /<elementProp name="([^"]+)" elementType="Argument">\s*<stringProp name="Argument\.name">\1<\/stringProp>\s*<stringProp name="Argument\.value">([^<]*)<\/stringProp>/g;

    content = content.replace(regex, (match, argName, argValue) => {
        if (!OVERRIDABLE.has(argName)) return match;
        // Skip if already parameterized (idempotent).
        if (argValue.startsWith('${__P(')) return match;
        changes++;
        const replacement = `\${__P(${argName},${argValue})}`;
        return match.replace(
            `<stringProp name="Argument.value">${argValue}</stringProp>`,
            `<stringProp name="Argument.value">${replacement}</stringProp>`
        );
    });

    if (changes > 0) {
        fs.writeFileSync(filepath, content, 'utf8');
    }
    return changes;
}

function walk(dir) {
    const results = [];
    for (const name of fs.readdirSync(dir)) {
        const fullpath = path.join(dir, name);
        const stat = fs.statSync(fullpath);
        if (stat.isDirectory()) {
            results.push(...walk(fullpath));
        } else if (name.endsWith('.jmx')) {
            results.push(fullpath);
        }
    }
    return results;
}

const files = walk(JMETER_ROOT);
console.log(`Processing ${files.length} .jmx file(s) under ${JMETER_ROOT}`);
for (const f of files) {
    const n = parameterizeFile(f);
    const rel = path.relative(path.join(__dirname, '..'), f).replace(/\\/g, '/');
    console.log(`  ${rel}: ${n} substitution(s)`);
}
