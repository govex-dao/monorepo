import React from "react";

interface TimeRangeSelectorProps {
  selectedRange: string;
  onRangeSelect: (range: string) => void;
}

const TimeRangeSelector: React.FC<TimeRangeSelectorProps> = ({
  selectedRange,
  onRangeSelect,
}) => {
  const ranges = ["1H", "4H", "1D", "MAX"];

  return (
    <div className="flex justify-end">
      <div className="inline-flex bg-gray-900 rounded-full p-1 border border-gray-800">
        {ranges.map((range) => (
          <button
            key={range}
            onClick={() => onRangeSelect(range)}
            className={`
              px-3 py-1 text-sm font-medium rounded-full transition-colors duration-200
              ${
                selectedRange === range
                  ? "bg-black text-gray-100"
                  : "text-gray-400 hover:text-gray-200"
              }
            `}
          >
            {range}
          </button>
        ))}
      </div>
    </div>
  );
};

export default TimeRangeSelector;
