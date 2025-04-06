import { getLargestSuiCoin, splitCoin } from '../create-pay-utils';
import { execSync } from 'child_process';

export const SUI_BIN = `sui`;
export const getActiveAddress = () => {
    return execSync(`${SUI_BIN} client active-address`, { encoding: 'utf8' }).trim();
};

// Combined creation function
const performCreatePayment = async () => {
    try {
       // const coinId = await getLargestSuiCoin({
       //     address: getActiveAddress(),
       //     network: 'testnet'
       // });
       // console.log('Largest coin ID:', coinId);

        const splitResult = await splitCoin({
            amount: 10000,
            network: 'devnet'
        });
        console.log('Split result:', splitResult);
        
        return splitResult;
    } catch (error) {
        console.error('Error during payment creation:', error);
        throw error;
    }
};

// Execute the function
performCreatePayment();

