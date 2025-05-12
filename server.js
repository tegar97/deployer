const express = require('express');
const bodyParser = require('body-parser');
const crypto = require('crypto');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = 9999;

const SECRET = '';

app.use(bodyParser.json({
    verify: (req, res, buf) => {
        req.rawBody = buf.toString();
    }
}));

function verifySignature(req, res, buf) {
    const signature = req.headers['x-hub-signature-256'];
    if (!signature) return false;

    const hmac = crypto.createHmac('sha256', SECRET);
    const digest = 'sha256=' + hmac.update(buf).digest('hex');
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(digest));
}

function verifySignature(req, res, rawBody) {
    if (!SECRET) {
        console.log('Secret kosong, melewati verifikasi signature');
        return true;
    }

    const signature = req.headers['x-hub-signature-256'];
    if (!signature || !signature.startsWith('sha256=')) {
        return false;
    }

    const hmac = crypto.createHmac('sha256', SECRET);
    const digest = 'sha256=' + hmac.update(rawBody).digest('hex');

    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(digest));
}

const allowedBranches = ['refs/heads/main', 'refs/heads/develop', 'refs/heads/release'];


app.post('/webhook', (req, res) => {
    const isValid = verifySignature(req, res, req.rawBody);

    if (!isValid) {
        return res.status(403).send('Invalid signature');
    }

    const event = req.headers['x-github-event'];
    const payload = req.body;
    const ref = payload.ref;
    const branchName = ref.split('/').pop();
    const commitMessages = payload.commits.map(commit => commit.message).join('\n');

    console.log(`✅ Received GitHub event: ${event}`);
    console.log('📦 Repository:', payload.repository.full_name);
    console.log('👤 Pushed by:', payload.pusher.name);
    console.log('🌿 Branch:', ref);
    console.log('📝 Commits:\n', payload.commits.map(commit => '- ' + commit.message).join('\n'));

    if (allowedBranches.includes(ref)) {
        const scriptPath = 'deploy.sh';

        console.log('📜 Script path:', scriptPath);
        if (!fs.existsSync(scriptPath)) {
          console.error('❌ Script tidak ditemukan:', scriptPath);
          return res.status(500).send('Script deploy tidak ditemukan');
        }

        console.log('📜 Script path:', scriptPath);
        
        const isWindows = process.platform === 'win32';
        let command, args;
        
        if (isWindows) {
            const wslPath = scriptPath
                .replace(/^([A-Z]):/, '/mnt/$1')
                .replace(/\\/g, '/')
                .toLowerCase();
            console.log('📜 WSL path:', wslPath);
            command = 'wsl';
            args = ['bash', wslPath];
        } else {
            command = 'bash';
            args = [scriptPath];
        }
        
        const child = spawn(command, args, {
            env: {
                ...process.env,
                BRANCH: branchName,
                COMMITS: commitMessages,
                REPO_NAME: payload.repository.name,
            }
        });

        child.stdout.on('data', (data) => {
            console.log('📢 Script Output:', data.toString());
        });

        child.stderr.on('data', (data) => {
            console.error('❌ Script Error:', data.toString());
        });

        child.on('close', (code) => {
            console.log(`✅ Script selesai dengan kode exit ${code}`);
        });

        child.on('error', (err) => {
            console.error(`❌ Error saat menjalankan script: ${err}`);
        });
    } else {
        console.log(`⛔ Branch ${ref} tidak di-handle. Dilewati.`);
    }

    res.status(200).send('Webhook received');
});

app.get('/', (req, res) => {
    res.send('Webhook server is running');
});

app.listen(PORT, () => {
    console.log(`Server is listening on port ${PORT}`);
});