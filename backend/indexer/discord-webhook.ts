import fs from 'fs/promises';
import path from 'path';

interface DiscordEmbed {
    title: string;
    color: number;
    author?: {
        name: string;
        icon_url?: string;
    };
    fields: Array<{
        name: string;
        value: string;
        inline: boolean;
    }>;
    timestamp: string;
}

interface DiscordWebhookOptions {
    webhookUrl: string;
    embed: DiscordEmbed;
    attachmentPath?: string | null;
    attachmentFilename?: string;
}

/**
 * Manually constructs a multipart/form-data request body with boundary
 */
function createMultipartBody(boundary: string, embed: DiscordEmbed, fileBuffer: Buffer, filename: string): Buffer {
    const textEncoder = new TextEncoder();
    
    // Build the multipart body parts
    const parts: Uint8Array[] = [];
    
    // Part 1: JSON payload
    parts.push(textEncoder.encode(`--${boundary}\r\n`));
    parts.push(textEncoder.encode('Content-Disposition: form-data; name="payload_json"\r\n'));
    parts.push(textEncoder.encode('Content-Type: application/json\r\n\r\n'));
    parts.push(textEncoder.encode(JSON.stringify({ embeds: [embed] })));
    parts.push(textEncoder.encode('\r\n'));
    
    // Part 2: File attachment
    parts.push(textEncoder.encode(`--${boundary}\r\n`));
    const mimeType = filename.endsWith('.jpg') || filename.endsWith('.jpeg') ? 'image/jpeg' : 'image/png';
    parts.push(textEncoder.encode(`Content-Disposition: form-data; name="files[0]"; filename="${filename}"\r\n`));
    parts.push(textEncoder.encode(`Content-Type: ${mimeType}\r\n\r\n`));
    parts.push(fileBuffer);
    parts.push(textEncoder.encode('\r\n'));
    
    // End boundary
    parts.push(textEncoder.encode(`--${boundary}--\r\n`));
    
    // Calculate total length
    const totalLength = parts.reduce((sum, part) => sum + part.length, 0);
    
    // Combine all parts into single buffer
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const part of parts) {
        if (part instanceof Buffer) {
            result.set(part, offset);
        } else {
            result.set(part, offset);
        }
        offset += part.length;
    }
    
    return Buffer.from(result);
}

/**
 * Sends a Discord webhook with optional image attachment
 */
export async function sendDiscordWebhook(options: DiscordWebhookOptions): Promise<void> {
    const { webhookUrl, embed, attachmentPath, attachmentFilename } = options;
    
    let hasAttachment = false;
    let imageBuffer: Buffer | null = null;
    let filename = attachmentFilename || 'image.png';
    
    // Try to read the attachment if path is provided
    if (attachmentPath) {
        try {
            const imagePath = path.join(process.cwd(), 'public', attachmentPath);
            
            imageBuffer = await fs.readFile(imagePath);
            
            // Extract actual file extension
            const ext = path.extname(attachmentPath);
            if (ext && attachmentFilename) {
                filename = attachmentFilename.replace(/\.[^/.]+$/, '') + ext;
            }
            
            hasAttachment = true;
            
            // Update embed to reference the attachment
            if (embed.author) {
                embed.author.icon_url = `attachment://${filename}`;
            }
        } catch (error) {
            console.log(`Could not read attachment: ${error instanceof Error ? error.message : 'Unknown error'}`);
            // Continue without attachment
        }
    }
    
    let response;
    
    if (hasAttachment && imageBuffer) {
        // Send with attachment using multipart/form-data
        const boundary = `----WebhookBoundary${Date.now()}${Math.random().toString(36)}`;
        const body = createMultipartBody(boundary, embed, imageBuffer, filename);
        
        response = await fetch(webhookUrl, {
            method: 'POST',
            headers: {
                'Content-Type': `multipart/form-data; boundary=${boundary}`,
            },
            body: body
        });
    } else {
        // Send without attachment
        response = await fetch(webhookUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ embeds: [embed] })
        });
    }
    
    if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Discord webhook failed: ${response.status} ${response.statusText} - ${errorText}`);
    }
}