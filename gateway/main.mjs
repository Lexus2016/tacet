import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { createGateway } from './server.mjs';

try {
  process.loadEnvFile(fileURLToPath(new URL('./.env', import.meta.url)));
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
}

const host = process.env.TACET_GATEWAY_HOST ?? '127.0.0.1';
const port = Number(process.env.TACET_GATEWAY_PORT ?? 8787);
const loopback = ['127.0.0.1', '::1'].includes(host);
const apiKey = process.env.OPENROUTER_API_KEY?.trim();
const groqKey = process.env.GROQ_API_KEY?.trim();
const ollamaKey = process.env.OLLAMA_API_KEY?.trim();
const localAdmin = loopback && process.env.TACET_GATEWAY_PUBLIC_ADMIN !== '1';
const registryPath = process.env.TACET_GATEWAY_CLIENT_REGISTRY;
const usagePath = process.env.TACET_GATEWAY_USAGE_DATABASE;
// Optional App Review access: review-access.json next to the usage database, {"email": "...", "code": "123456"}.
// Remove the file to switch it off. / Необов'язковий доступ для App Review: файл review-access.json поруч із базою.
function readReviewer() {
  if (!usagePath) return undefined;
  try {
    const value = JSON.parse(readFileSync(resolve(dirname(usagePath), 'review-access.json'), 'utf8'));
    return typeof value?.email === 'string' && /^\d{6}$/.test(String(value?.code)) ? value : undefined;
  } catch {
    return undefined;
  }
}
const smtpHost = process.env.TACET_AUTH_SMTP_HOST?.trim();
let emailLogin;
if (smtpHost) {
  const { default: nodemailer } = await import('nodemailer');
  const smtpPort = Number(process.env.TACET_AUTH_SMTP_PORT ?? 587);
  const from = process.env.TACET_AUTH_FROM?.trim();
  const user = process.env.TACET_AUTH_SMTP_USER;
  const pass = process.env.TACET_AUTH_SMTP_PASSWORD;
  const secure = [465, 2465].includes(smtpPort);
  if (!Number.isInteger(smtpPort) || smtpPort < 1 || smtpPort > 65_535 || !from || /[\r\n]/.test(from) ||
      Boolean(user) !== Boolean(pass)) {
    throw new TypeError('Invalid SMTP settings / Некоректні параметри пошти');
  }
  const transport = nodemailer.createTransport({
    host: smtpHost, port: smtpPort, secure, requireTLS: !secure,
    ...(user && { auth: { user, pass } }),
    connectionTimeout: 8_000, greetingTimeout: 8_000, socketTimeout: 12_000,
    tls: { minVersion: 'TLSv1.2' },
  });
  emailLogin = {
    secret: process.env.TACET_AUTH_CODE_SECRET,
    trustedProxies: process.env.TACET_AUTH_TRUSTED_PROXIES?.split(',').map(value => value.trim()),
    allowedEmails: process.env.TACET_AUTH_ALLOWED_EMAILS?.split(',').map(value => value.trim()).filter(Boolean),
    reviewer: readReviewer(),
    async sendCode({ email, code }) {
      // Log the outcome without the address or the code: delivery faults must be visible to the operator.
      // Журналюємо результат без адреси й коду: збої доставки мають бути видимі операторові.
      const domain = email.slice(email.lastIndexOf('@') + 1);
      try {
        const receipt = await transport.sendMail({
          from, to: email, subject: 'Tacet sign-in code / Код входу в Tacet',
          text: `Your Tacet sign-in code / Ваш код входу в Tacet\n\n${code}\n\n` +
            'This code expires in 10 minutes. / Код діє 10 хвилин.\n' +
            'If you did not ask for a code, you can ignore this message. / Якщо ви не просили код, проігноруйте цей лист.',
        });
        if (!receipt.accepted?.length) throw new Error('Mail was not accepted / Поштовий сервер відхилив лист');
        console.log(`Sign-in mail accepted for @${domain}: ${receipt.response ?? ''}`);
      } catch (error) {
        console.error(`Sign-in mail failed for @${domain}: ${error?.responseCode ?? ''} ${error?.message ?? error}`);
        throw error;
      }
    },
  };
}
if (!Number.isInteger(port) || port < 1 || port > 65_535) {
  throw new TypeError('Invalid gateway port / Некоректний порт шлюзу');
}

const gateway = createGateway({
  configPath: process.env.TACET_GATEWAY_CONFIG ? resolve(process.env.TACET_GATEWAY_CONFIG) :
    fileURLToPath(new URL('./data/routes.json', import.meta.url)),
  adminToken: process.env.TACET_GATEWAY_ADMIN_TOKEN,
  clientToken: process.env.TACET_GATEWAY_CLIENT_TOKEN || (loopback && !registryPath ? randomBytes(32).toString('hex') : undefined),
  registryPath: registryPath ? resolve(registryPath) : undefined,
  usagePath: usagePath ? resolve(usagePath) : undefined,
  emailLogin,
  pilotAccounts: process.env.TACET_GATEWAY_PILOT_ACCOUNTS?.split(',').map(value => value.trim()).filter(Boolean),
  apiKey, groqKey, ollamaKey, localAdmin,
});
gateway.listen(port, host, () => {
  console.log(`Tacet gateway / Шлюз Tacet: http://${host}:${port}/admin/`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => gateway.close());
}
