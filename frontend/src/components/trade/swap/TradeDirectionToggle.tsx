import React from 'react';

type TradeDirection = 'assetToStable' | 'stableToAsset';

interface TradeDirectionToggleProps {
  tradeDirection: TradeDirection;
  setTradeDirection: (direction: TradeDirection) => void;
}

const TradeDirectionToggle: React.FC<TradeDirectionToggleProps> = ({
  tradeDirection,
  setTradeDirection,
}) => {
  return (
    <div className="flex bg-gray-800/70 p-1 rounded-lg relative">
      <div
        className={`absolute top-1 bottom-1 w-1/2 rounded-md transition-all duration-300 shadow-md ${tradeDirection === 'stableToAsset' ? 'left-1 bg-green-500' : 'left-[calc(50%-1px)] bg-red-500'
          }`}
      ></div>
      <button
        type="button"
        onClick={() => setTradeDirection('stableToAsset')}
        className={`flex-1 py-2 rounded-md font-medium transition-all duration-200 flex items-center justify-center z-10 ${tradeDirection === 'stableToAsset'
            ? 'text-white'
            : 'text-gray-400 hover:text-white'
          }`}
      >
        Buy
      </button>
      <button
        type="button"
        onClick={() => setTradeDirection('assetToStable')}
        className={`flex-1 py-2 rounded-md font-medium transition-all duration-200 flex items-center justify-center z-10 ${tradeDirection === 'assetToStable'
            ? 'text-white'
            : 'text-gray-400 hover:text-white'
          }`}
      >
        Sell
      </button>
    </div>
  );
};

export const TradeDirectionSwapButton: React.FC<TradeDirectionToggleProps> = ({ tradeDirection, setTradeDirection }) => {
  return (
    <div className="flex justify-center -my-[22px] z-10">
      <div
        className="bg-gradient-to-r from-blue-600/90 to-blue-500/90 border-4 border-gray-900 rounded-full p-1.5 w-9 h-9 flex items-center justify-center cursor-pointer hover:from-blue-500/90 hover:to-blue-400/90 transition-all duration-300 shadow-lg transform hover:scale-105 active:scale-95"
        onClick={() => setTradeDirection(tradeDirection === 'assetToStable' ? 'stableToAsset' : 'assetToStable')}
        title={`Switch to ${tradeDirection === 'assetToStable' ? 'Stable to Asset' : 'Asset to Stable'}`}
      >
        <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4 text-white drop-shadow-sm" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4" />
        </svg>
      </div>
    </div>
  );
};


export default TradeDirectionToggle; 