import { ShowMoreDetails } from '@/components/ShowMoreDetails';
import React, { Dispatch, SetStateAction, useState } from 'react';

interface TradeInsightProps {
  tradeDirection: 'assetToStable' | 'stableToAsset';
  setTradeDirection: Dispatch<SetStateAction<'assetToStable' | 'stableToAsset'>>;
  selectedOutcome: string;
  outcomeMessages: string[];
  amount: string;
  updateFromAmount: (amount: string) => void;
  averagePrice: string;
  assetSymbol: string;
  stableSymbol: string;
  stableScale: number;
  assetScale: number;
}

const TradeInsight: React.FC<TradeInsightProps> = ({
  tradeDirection,
  setTradeDirection,
  selectedOutcome,
  outcomeMessages,
  amount,
  updateFromAmount,
  averagePrice,
  assetSymbol,
  stableSymbol,
  stableScale,
  assetScale
}) => {
  const [showTradeInsight, setShowTradeInsight] = useState<boolean>(false);
  const isBullish = tradeDirection === 'stableToAsset';
  const selectedOutcomeIndex = parseInt(selectedOutcome);
  const outcomeMessage = outcomeMessages[selectedOutcomeIndex];
  const outcomeClass = selectedOutcome !== "0" ? "text-green-300" : "text-red-300";
  const fromSymbol = isBullish ? stableSymbol : assetSymbol;
  const scale = isBullish ? stableScale : assetScale;

  
  function renderAmountInput(symbol: string, scale: number) {
    return (
      <span className="font-mono bg-black/30 px-2 py-0.5 rounded-md font-medium">
        <input
          type="number"
          value={amount}
          onChange={(e) => updateFromAmount(e.target.value)}
          className="w-12 bg-transparent text-white border-b border-dashed border-gray-500 focus:outline-none font-medium appearance-none [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none [-moz-appearance:textfield]"
          step={1 / Number(scale)}
          aria-label={`Enter amount in ${symbol}`}
        /> {symbol}
      </span>
    );
  }

  function renderTradeButton(isPositive: boolean) {
    return (
      <button
        className={`${isPositive ? "bg-green-900/40 text-green-300 hover:bg-green-800/40" : "bg-red-900/40 text-red-300 hover:bg-red-800/40"} font-medium px-3 py-1.5 rounded-md mr-2 inline-flex items-center shadow-sm cursor-pointer transition-colors duration-200`}
        onClick={() => setTradeDirection(p => p === "stableToAsset" ? 'assetToStable' : 'stableToAsset')}
      >
        <svg xmlns="http://www.w3.org/2000/svg" className="h-3.5 w-3.5 mr-1.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d={isPositive ? "M5 15l7-7 7 7" : "M19 9l-7 7-7-7"} />
        </svg>
        {isPositive ? "BULLISH" : "BEARISH"}
      </button>
    );
  }

  function renderTradeDescription() {
    return (
      <div>
        {renderTradeButton(isBullish)}
        <p className="leading-relaxed mt-2.5 text-xs">
          You expect the price to {isBullish 
            ? <strong className="text-green-300">rise</strong> 
            : <strong className="text-red-300">fall</strong>} if <strong className={outcomeClass}>{outcomeMessage}</strong> occurs.
        </p>
        <p className="leading-relaxed mt-1 text-xs">
          You're betting {renderAmountInput(fromSymbol, scale)} that
          the price of {isBullish ? stableSymbol : assetSymbol} <span className="font-mono bg-black/30 px-2 py-0.5 rounded-md font-medium">${averagePrice}</span> is too {isBullish ? 'low' : 'high'}.
        </p>
      </div>
    );
  }

  return (
    <div>
      <div className='flex justify-end'>
        <ShowMoreDetails show={showTradeInsight} setShow={setShowTradeInsight} title='Beginner Guide' />
      </div>
      {showTradeInsight && (
        <div className="bg-gray-800/20 rounded-lg p-4 mb-3 text-sm border border-gray-700/20 shadow-lg backdrop-blur-sm text-gray-200">
          {renderTradeDescription()}
        </div>
      )}
    </div>
  );
};

export default TradeInsight;