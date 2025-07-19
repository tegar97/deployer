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

function deployApp(appName) {
    return new Promise((resolve, reject) => {
        const scriptPath = path.join(__dirname, 'deploy.sh');

        console.log(`📜 Deploying app: ${appName}`);
        
        if (!fs.existsSync(scriptPath)) {
            console.error('❌ Script tidak ditemukan:', scriptPath);
            reject(new Error('Script deploy tidak ditemukan'));
            return;
        }
        
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
                REPO_NAME: appName || '',
            }
        });

        let output = '';
        let errorOutput = '';

        child.stdout.on('data', (data) => {
            const dataStr = data.toString();
            output += dataStr;
            console.log(`📢 [${appName}] Output:`, dataStr);
        });

        child.stderr.on('data', (data) => {
            const dataStr = data.toString();
            errorOutput += dataStr;
            console.error(`❌ [${appName}] Error:`, dataStr);
        });

        child.on('close', (code) => {
            console.log(`✅ Script selesai untuk ${appName} dengan kode exit ${code}`);
            if (code === 0) {
                resolve({ appName, success: true, output });
            } else {
                reject(new Error(`Script failed with code ${code}: ${errorOutput}`));
            }
        });

        child.on('error', (err) => {
            console.error(`❌ Error saat menjalankan script untuk ${appName}: ${err}`);
            reject(err);
        });
    });
}

function deployApp2(appName) {
    return new Promise((resolve, reject) => {
        const scriptPath = path.join(__dirname, 'deploy2.sh');

        console.log(`📜 Deploying app (direct): ${appName}`);
        
        if (!fs.existsSync(scriptPath)) {
            console.error('❌ Script tidak ditemukan:', scriptPath);
            reject(new Error('Script deploy2 tidak ditemukan'));
            return;
        }
        
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
                REPO_NAME: appName || '',
            }
        });

        let output = '';
        let errorOutput = '';

        child.stdout.on('data', (data) => {
            const dataStr = data.toString();
            output += dataStr;
            console.log(`📢 [${appName}] Output:`, dataStr);
        });

        child.stderr.on('data', (data) => {
            const dataStr = data.toString();
            errorOutput += dataStr;
            console.error(`❌ [${appName}] Error:`, dataStr);
        });

        child.on('close', (code) => {
            console.log(`✅ Script selesai untuk ${appName} dengan kode exit ${code}`);
            if (code === 0) {
                resolve({ appName, success: true, output });
            } else {
                reject(new Error(`Script failed with code ${code}: ${errorOutput}`));
            }
        });

        child.on('error', (err) => {
            console.error(`❌ Error saat menjalankan script untuk ${appName}: ${err}`);
            reject(err);
        });
    });
}

// Load configuration
function loadConfig() {
    try {
        const configPath = path.join(__dirname, 'config.json');
        if (fs.existsSync(configPath)) {
            const configData = fs.readFileSync(configPath, 'utf8');
            return JSON.parse(configData);
        }
        return { apps: {}, defaults: { targetPort: 3000, nodePort: 30000 } };
    } catch (error) {
        console.error('Error loading config:', error);
        return { apps: {}, defaults: { targetPort: 3000, nodePort: 30000 } };
    }
}

app.post('/webhook', (req, res) => {
    const isValid = verifySignature(req, res, req.rawBody);

    if (!isValid) {
        return res.status(403).send('Invalid signature');
    }

    const event = req.headers['x-github-event'];
    // 💡 Abaikan event 'ping'
    if (event === 'ping') {
        console.log('📡 Ping event diterima, tidak melakukan deploy.');
        return res.status(200).send('Ping event received');
    }
    const payload = req.body;
    const ref = payload?.ref;
    // const branchName = ref.split('/').pop();
    // const commitMessages = payload.commits.map(commit => commit.message).join('\n');

    console.log(`✅ Received GitHub event: ${event}`);
    if (payload?.repository) {
        console.log('📦 Repository:', payload.repository.full_name);
    }
    if (payload?.pusher) {
        console.log('👤 Pushed by:', payload.pusher.name);
    }
    if (payload?.commits) {
        console.log('📝 Commits:\n', payload.commits.map(commit => '- ' + commit.message).join('\n'));
    }

    // if spesific commit use deploy2 for testing not use blue green deployment
    if (payload?.commits) {
        const commitMessages = payload.commits.map(commit => commit.message).join('\n');
        if (commitMessages.includes('deploy2')) {
            console.log('🔄 Deploying app (direct) for testing');
            return deployApp2(payload?.repository?.name);
        } else {
            console.log('🔄 Deploying app (blue-green) ');
            return deployApp(payload?.repository?.name);
        }
    }



    
    // const isWindows = process.platform === 'win32';
    // let command, args;
    
    // if (isWindows) {
    //     const wslPath = scriptPath
    //         .replace(/^([A-Z]):/, '/mnt/$1')
    //         .replace(/\\/g, '/')
    //         .toLowerCase();
    //     console.log('📜 WSL path:', wslPath);
    //     command = 'wsl';
    //     args = ['bash', wslPath];
    // } else {
    //     command = 'bash';
    //     args = [scriptPath];
    // }
    
    // const child = spawn(command, args, {
    //     env: {
    //         // BRANCH: branchName,
    //         // COMMITS: commitMessages,
    //         REPO_NAME: payload?.repository?.name || '',
    //     }
    // });

    // child.stdout.on('data', (data) => {
    //     console.log('📢 Script Output:', data.toString());
    // });

    // child.stderr.on('data', (data) => {
    //     console.error('❌ Script Error:', data.toString());
    // });

    // child.on('close', (code) => {
    //     console.log(`✅ Script selesai dengan kode exit ${code}`);
    // });

    // child.on('error', (err) => {
    //     console.error(`❌ Error saat menjalankan script: ${err}`);
    // });

    res.status(200).send('Webhook received');
});

// Ping endpoint
app.get('/ping', (req, res) => {
    res.status(200).json({ 
        status: 'ok',
        timestamp: new Date().toISOString()
    });
});

// Init endpoint to deploy all apps from config.json
app.post('/init', async (req, res) => {
    try {
        const config = loadConfig();
        const appNames = Object.keys(config.apps);
        
        if (appNames.length === 0) {
            return res.status(400).json({ 
                success: false, 
                message: 'No apps configured in config.json' 
            });
        }
        
        console.log(`📋 Found ${appNames.length} apps to deploy: ${appNames.join(', ')}`);
        
        const results = [];
        const errors = [];
        
        for (const appName of appNames) {
            try {
                const result = await deployApp(appName);
                results.push(result);
            } catch (error) {
                console.error(`Failed to deploy ${appName}:`, error);
                errors.push({ appName, error: error.message });
            }
        }
        
        res.status(200).json({ 
            success: true,
            deployed: results.map(r => r.appName),
            failed: errors.map(e => e.appName),
            errors: errors
        });
    } catch (error) {
        console.error('Error processing init request:', error);
        res.status(500).json({ 
            success: false, 
            message: 'Failed to process init request', 
            error: error.message 
        });
    }
});

// Init2 endpoint to deploy all apps from config.json (direct deployment without blue-green)
app.post('/init2', async (req, res) => {
    try {
        const config = loadConfig();
        const appNames = Object.keys(config.apps);
        
        if (appNames.length === 0) {
            return res.status(400).json({ 
                success: false, 
                message: 'No apps configured in config.json' 
            });
        }
        
        console.log(`📋 Found ${appNames.length} apps to deploy (direct): ${appNames.join(', ')}`);
        
        const results = [];
        const errors = [];
        
        for (const appName of appNames) {
            try {
                const result = await deployApp2(appName);
                results.push(result);
            } catch (error) {
                console.error(`Failed to deploy ${appName}:`, error);
                errors.push({ appName, error: error.message });
            }
        }
        
        res.status(200).json({ 
            success: true,
            deployed: results.map(r => r.appName),
            failed: errors.map(e => e.appName),
            errors: errors
        });
    } catch (error) {
        console.error('Error processing init2 request:', error);
        res.status(500).json({ 
            success: false, 
            message: 'Failed to process init2 request', 
            error: error.message 
        });
    }
});

app.get('/', (req, res) => {
    res.send('Webhook server is running');
});

app.listen(PORT, () => {
    console.log(`Server is listening on port ${PORT}`);
});