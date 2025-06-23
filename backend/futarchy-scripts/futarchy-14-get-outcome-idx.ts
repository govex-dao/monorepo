import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { existsSync, unlinkSync, writeFileSync } from 'fs';

export const SUI_BIN = `sui`;

// Function to read JSON file
const readJsonFile = (filename: string) => {
    const filePath = path.join(__dirname, '../futarchy-results', filename);
    try {
        const fileContent = fs.readFileSync(filePath, 'utf8');
        return JSON.parse(fileContent);
    } catch (error) {
        console.error(`Error reading ${filename}:`, error);
        throw error;
    }
};

// Function to get object information from sui client
const getObjectInfo = (objectId: string) => {
    try {
        // Add --json flag and redirect stderr to stdout
        const command = `${SUI_BIN} client object ${objectId} --json 2>&1`;
        console.log('Executing command:', command);
        
        const result = execSync(command, { 
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'pipe']
        });
        
        console.log('Raw result:', result); // Debug log
        
        try {
            return JSON.parse(result);
        } catch (parseError) {
            console.error('Failed to parse result:', parseError);
            // If parsing fails, try to extract JSON from the output
            const jsonMatch = result.match(/\{[\s\S]*\}/);
            if (jsonMatch) {
                return JSON.parse(jsonMatch[0]);
            }
            throw parseError;
        }
    } catch (error) {
        console.error(`Error fetching object info for ${objectId}:`, error);
        throw error;
    }
};

// Function to parse specific fields from object info
const parseObjectResults = (results: any) => {
    return {
        outcome: results.content?.fields?.outcome ?? null
    };
};

// Main function to get token info and save results
const getTokenInfo = async () => {
    try {
        // Read escrow results to get token ID
        const escrowResults = readJsonFile('escrow-deposit-short.json');
        console.log('Token ID:', escrowResults.outcomeToken0);
        
        // Get object info from sui client
        const results = getObjectInfo(escrowResults.outcomeToken0);
        console.log('Parsed results:', JSON.stringify(results, null, 2));

        const resultsDir = 'futarchy-results';
        const fileNames = ['get-index-short.json', 'get-index-full.json'];
        const filePaths = fileNames.map(fileName => 
            path.join(__dirname, '..', resultsDir, fileName)
        );

        // Create directory if it doesn't exist
        const dirPath = path.join(__dirname, '..', resultsDir);
        if (!existsSync(dirPath)) {
            fs.mkdirSync(dirPath, { recursive: true });
        }

        // Delete existing files if they exist
        filePaths.forEach(filePath => {
            if (existsSync(filePath)) {
                unlinkSync(filePath);
            }
        });

        // Write new files
        writeFileSync(
            filePaths[0],
            JSON.stringify(parseObjectResults(results), null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

        writeFileSync(
            filePaths[1],
            JSON.stringify(results, null, 2),
            { encoding: 'utf8', flag: 'w' }
        );

        return results;

    } catch (error) {
        console.error('Error getting token info:', error);
        throw error;
    }
};

// Execute if running directly
if (require.main === module) {
    getTokenInfo().catch(error => {
        console.error('Script failed:', error);
        process.exit(1);
    });
}

export { getTokenInfo };