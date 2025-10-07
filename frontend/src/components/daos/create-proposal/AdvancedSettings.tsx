import React from "react";

interface DaoData {
  asset_decimals: number;
  stable_decimals: number;
  asset_symbol: String;
  stable_symbol: String;
  minAssetAmount: string;
  minStableAmount: string;
}

interface AdvancedSettingsProps {
  showAdvancedSettings: boolean;
  setShowAdvancedSettings: (value: boolean) => void;
  customAmounts: number[];
  setCustomAmounts: (amounts: number[]) => void;
  outcomeMessages: string[];
  daoData: DaoData | null;
}

const convertToDisplayAmount = (amount: string, decimals: number) => {
  return (parseInt(amount) / Math.pow(10, decimals)).toString();
};

export const AdvancedSettings: React.FC<AdvancedSettingsProps> = ({
  showAdvancedSettings,
  setShowAdvancedSettings,
  customAmounts,
  setCustomAmounts,
  outcomeMessages,
  daoData,
}) => {
  return (
    <div className="mt-6 pt-6">
      <div className="flex items-center gap-2 mb-4">
        <span className="text-sm font-medium text-gray-200">
          Advanced Settings
        </span>
        <button
          type="button"
          onClick={() => setShowAdvancedSettings(!showAdvancedSettings)}
          className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
            showAdvancedSettings ? "bg-blue-500" : "bg-gray-700"
          }`}
        >
          <span
            className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
              showAdvancedSettings ? "translate-x-6" : "translate-x-1"
            }`}
          />
        </button>
      </div>

      {showAdvancedSettings && (
        <div className="space-y-4 p-4 rounded-lg">
          <div className="grid grid-cols-3 gap-4 mb-2">
            <div className="text-sm font-medium text-gray-300">Outcome</div>
            <div className="text-sm font-medium text-gray-300">
              {`${daoData?.asset_symbol || "Asset"} Amount`}
            </div>
            <div className="text-sm font-medium text-gray-300">
              {`${daoData?.stable_symbol || "Stable"} Amount`}
            </div>
          </div>
          {outcomeMessages.map((outcome, index) => (
            <div key={index} className="grid grid-cols-3 gap-4 items-center">
              <div className="text-sm text-gray-200">{outcome}</div>
              <div>
                <input
                  type="number"
                  value={customAmounts[index * 2] || ""}
                  step={Math.pow(10, -(daoData?.asset_decimals || 0))}
                  onChange={(e) => {
                    const newAmounts = [...customAmounts];
                    newAmounts[index * 2] = parseFloat(e.target.value);
                    setCustomAmounts(newAmounts);
                  }}
                  min={parseFloat(
                    convertToDisplayAmount(
                      daoData?.minAssetAmount || "0",
                      daoData?.asset_decimals || 0,
                    ),
                  )}
                  className={`w-full p-2 rounded bg-gray-900 border ${
                    customAmounts[index * 2] <
                    parseFloat(
                      convertToDisplayAmount(
                        daoData?.minAssetAmount || "0",
                        daoData?.asset_decimals || 0,
                      ),
                    )
                      ? "border-red-500"
                      : "border-gray-700"
                  }`}
                />
                {customAmounts[index * 2] <
                  parseFloat(
                    convertToDisplayAmount(
                      daoData?.minAssetAmount || "0",
                      daoData?.asset_decimals || 0,
                    ),
                  ) && (
                  <p className="text-xs text-red-500 mt-1">
                    Below minimum (
                    {convertToDisplayAmount(
                      daoData?.minAssetAmount || "0",
                      daoData?.asset_decimals || 0,
                    )}
                    )
                  </p>
                )}
              </div>
              <div>
                <input
                  type="number"
                  value={customAmounts[index * 2 + 1] || ""}
                  step={Math.pow(10, -(daoData?.stable_decimals || 0))}
                  onChange={(e) => {
                    const newAmounts = [...customAmounts];
                    newAmounts[index * 2 + 1] = parseFloat(e.target.value);
                    setCustomAmounts(newAmounts);
                  }}
                  min={parseFloat(
                    convertToDisplayAmount(
                      daoData?.minStableAmount || "0",
                      daoData?.stable_decimals || 0,
                    ),
                  )}
                  className={`w-full p-2 rounded bg-gray-900 border ${
                    customAmounts[index * 2 + 1] <
                    parseFloat(
                      convertToDisplayAmount(
                        daoData?.minStableAmount || "0",
                        daoData?.stable_decimals || 0,
                      ),
                    )
                      ? "border-red-500"
                      : "border-gray-700"
                  }`}
                />
                {customAmounts[index * 2 + 1] <
                  parseFloat(
                    convertToDisplayAmount(
                      daoData?.minStableAmount || "0",
                      daoData?.stable_decimals || 0,
                    ),
                  ) && (
                  <p className="text-xs text-red-500 mt-1">
                    Below minimum (
                    {convertToDisplayAmount(
                      daoData?.minStableAmount || "0",
                      daoData?.stable_decimals || 0,
                    )}
                    )
                  </p>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};
