import { ApnsClient, ApnsError, Host, Notification } from 'apns2';

export type MessagePushPayload = {
  type: 'message.new';
  conversationId: string;
  conversationTitle: string;
  messageId: string;
  senderId: string;
  senderDisplayName: string;
  preview: string;
};

export type ActionPushPayload = {
  type: 'action.new';
  conversationId: string;
  conversationTitle: string;
  actionId: string;
  createdBy: string;
  createdByDisplayName: string;
  preview: string;
};

export type PushPayload = MessagePushPayload | ActionPushPayload;

let client: ApnsClient | undefined;

export function isApnsConfigured(): boolean {
  return Boolean(
    process.env.APNS_KEY_ID &&
      process.env.APNS_TEAM_ID &&
      process.env.APNS_BUNDLE_ID &&
      process.env.APNS_PRIVATE_KEY,
  );
}

function loadSigningKey(): Buffer {
  const raw = process.env.APNS_PRIVATE_KEY!;
  const normalized = raw.includes('\\n') ? raw.replace(/\\n/g, '\n') : raw;
  return Buffer.from(normalized);
}

export function getApnsClient(): ApnsClient | null {
  if (!isApnsConfigured()) return null;
  if (!client) {
    const useSandbox = process.env.APNS_USE_SANDBOX === 'true';
    client = new ApnsClient({
      team: process.env.APNS_TEAM_ID!,
      keyId: process.env.APNS_KEY_ID!,
      signingKey: loadSigningKey(),
      defaultTopic: process.env.APNS_BUNDLE_ID!,
      host: useSandbox ? Host.development : Host.production,
      keepAlive: true,
    });
  }
  return client;
}

export function parsePushPayload(payload: unknown): PushPayload | null {
  return parseMessagePushPayload(payload) ?? parseActionPushPayload(payload);
}

export function parseMessagePushPayload(payload: unknown): MessagePushPayload | null {
  if (!payload || typeof payload !== 'object') return null;
  const data = payload as Record<string, unknown>;
  if (data.type !== 'message.new') return null;

  const conversationId = data.conversationId;
  const conversationTitle = data.conversationTitle;
  const messageId = data.messageId;
  const senderId = data.senderId;
  const senderDisplayName = data.senderDisplayName;
  const preview = data.preview;

  if (
    typeof conversationId !== 'string' ||
    typeof messageId !== 'string' ||
    typeof senderId !== 'string' ||
    typeof preview !== 'string'
  ) {
    return null;
  }

  return {
    type: 'message.new',
    conversationId,
    conversationTitle:
      typeof conversationTitle === 'string' && conversationTitle.length > 0
        ? conversationTitle
        : 'Conversation',
    messageId,
    senderId,
    senderDisplayName:
      typeof senderDisplayName === 'string' && senderDisplayName.length > 0
        ? senderDisplayName
        : 'Someone',
    preview,
  };
}

export function parseActionPushPayload(payload: unknown): ActionPushPayload | null {
  if (!payload || typeof payload !== 'object') return null;
  const data = payload as Record<string, unknown>;
  if (data.type !== 'action.new') return null;

  const conversationId = data.conversationId;
  const conversationTitle = data.conversationTitle;
  const actionId = data.actionId;
  const createdBy = data.createdBy;
  const createdByDisplayName = data.createdByDisplayName;
  const preview = data.preview;

  if (
    typeof conversationId !== 'string' ||
    typeof actionId !== 'string' ||
    typeof createdBy !== 'string' ||
    typeof preview !== 'string'
  ) {
    return null;
  }

  return {
    type: 'action.new',
    conversationId,
    conversationTitle:
      typeof conversationTitle === 'string' && conversationTitle.length > 0
        ? conversationTitle
        : 'Conversation',
    actionId,
    createdBy,
    createdByDisplayName:
      typeof createdByDisplayName === 'string' && createdByDisplayName.length > 0
        ? createdByDisplayName
        : 'Someone',
    preview,
  };
}

export async function sendPush(
  deviceToken: string,
  payload: PushPayload,
): Promise<void> {
  const apns = getApnsClient();
  if (!apns) throw new Error('APNs is not configured');

  if (payload.type === 'message.new') {
    const notification = new Notification(deviceToken, {
      alert: {
        title: payload.conversationTitle,
        subtitle: payload.senderDisplayName,
        body: payload.preview,
      },
      sound: 'default',
      threadId: payload.conversationId,
      data: {
        type: payload.type,
        conversationId: payload.conversationId,
        messageId: payload.messageId,
        senderId: payload.senderId,
      },
    });
    await apns.send(notification);
    return;
  }

  const notification = new Notification(deviceToken, {
    alert: {
      title: payload.conversationTitle,
      subtitle: payload.createdByDisplayName,
      body: `Confirmation requested: ${payload.preview}`,
    },
    sound: 'default',
    threadId: payload.conversationId,
    data: {
      type: payload.type,
      conversationId: payload.conversationId,
      actionId: payload.actionId,
      createdBy: payload.createdBy,
    },
  });
  await apns.send(notification);
}

/** @deprecated Use sendPush */
export async function sendMessagePush(
  deviceToken: string,
  payload: MessagePushPayload,
): Promise<void> {
  await sendPush(deviceToken, payload);
}

export function isInvalidDeviceTokenError(err: unknown): boolean {
  if (err instanceof ApnsError) {
    return err.reason === 'BadDeviceToken' || err.reason === 'Unregistered';
  }
  return false;
}
