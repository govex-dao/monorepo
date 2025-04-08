import React, { useState, useEffect } from "react";
import { InfoCircledIcon } from "@radix-ui/react-icons";

interface TimeInputProps {
  label: string;
  tooltip: string;
  valueMs: number;
  onChange: (newValueMs: number) => void;
}

const TimeInput: React.FC<TimeInputProps> = ({
  label,
  tooltip,
  valueMs,
  onChange,
}) => {
  const MILLISECONDS_IN_DAY = 24 * 60 * 60 * 1000;
  const MILLISECONDS_IN_HOUR = 60 * 60 * 1000;

  // Calculate initial days and hours from the given milliseconds.
  const initialDays = Math.floor(valueMs / MILLISECONDS_IN_DAY);
  const initialHours = Math.floor(
    (valueMs % MILLISECONDS_IN_DAY) / MILLISECONDS_IN_HOUR,
  );

  // Local state to control the input values as strings.
  const [daysInput, setDaysInput] = useState<string>(String(initialDays));
  const [hoursInput, setHoursInput] = useState<string>(String(initialHours));

  // Update local state if the external value changes.
  useEffect(() => {
    const newDays = Math.floor(valueMs / MILLISECONDS_IN_DAY);
    const newHours = Math.floor(
      (valueMs % MILLISECONDS_IN_DAY) / MILLISECONDS_IN_HOUR,
    );
    setDaysInput(String(newDays));
    setHoursInput(String(newHours));
  }, [valueMs]);

  // Handle days change: update local state and notify parent if valid.
  const handleDaysChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const inputValue = e.target.value;
    setDaysInput(inputValue);
    const parsedDays = parseInt(inputValue, 10);
    if (!isNaN(parsedDays)) {
      const parsedHours = parseInt(hoursInput, 10) || 0;
      onChange(
        parsedDays * MILLISECONDS_IN_DAY + parsedHours * MILLISECONDS_IN_HOUR,
      );
    }
  };

  // Handle hours change: update local state and notify parent if valid.
  const handleHoursChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const inputValue = e.target.value;
    setHoursInput(inputValue);
    const parsedHours = parseInt(inputValue, 10);
    if (!isNaN(parsedHours)) {
      // Clamp hours between 0 and 24.
      const normalizedHours = Math.min(Math.max(parsedHours, 0), 24);
      const parsedDays = parseInt(daysInput, 10) || 0;
      onChange(
        parsedDays * MILLISECONDS_IN_DAY +
          normalizedHours * MILLISECONDS_IN_HOUR,
      );
    }
  };

  // On blur for days: normalize the input by clamping any negative values to 0.
  const handleDaysBlur = () => {
    const parsed = Math.max(0, parseInt(daysInput, 10) || 0);
    setDaysInput(String(parsed));
  };

  // On blur for hours: normalize and clamp the input between 0 and 24.
  const handleHoursBlur = () => {
    const parsed = parseInt(hoursInput, 10) || 0;
    const clamped = Math.min(Math.max(parsed, 0), 24);
    setHoursInput(String(clamped));
  };

  return (
    <div className="space-y-2">
      <div className="flex items-center space-x-2">
        <label className="block text-sm font-medium">{label}</label>
        <div className="relative group">
          <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600 cursor-help" />
          <div className="absolute left-1/2 -translate-x-1/2 bottom-full mb-2 px-3 py-2 bg-gray-900 text-white text-sm rounded-lg opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity duration-200 w-64 z-50">
            {tooltip}
          </div>
        </div>
      </div>
      <div className="flex space-x-2">
        <div className="flex-1">
          <label className="block text-xs">Days</label>
          <input
            type="number"
            value={daysInput}
            onChange={handleDaysChange}
            onBlur={handleDaysBlur}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            min="0"
            step="1"
          />
        </div>
        <div className="flex-1">
          <label className="block text-xs">Hours</label>
          <input
            type="number"
            value={hoursInput}
            onChange={handleHoursChange}
            onBlur={handleHoursBlur}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            min="0"
            max="24"
            step="1"
          />
        </div>
      </div>
    </div>
  );
};

export default TimeInput;
