import React, { useReducer, useEffect } from 'react';
import { Tooltip } from "@radix-ui/themes";
import { InfoCircledIcon } from '@radix-ui/react-icons';

// Constants defined outside component to avoid recreation on each render
const MILLISECONDS_IN_DAY = 24 * 60 * 60 * 1000;
const MILLISECONDS_IN_HOUR = 60 * 60 * 1000;
const MAX_HOURS = 24;
const MIN_VALUE = 0;

interface TimeInputProps {
  label: string;
  tooltip: string;
  valueMs: number;
  onChange: (newValueMs: number) => void;
}

// State interface for our reducer
interface TimeState {
  days: string;
  hours: string;
  error?: string;
}

// Action types for our reducer
type TimeAction =
  | { type: 'SET_DAYS'; payload: string }
  | { type: 'SET_HOURS'; payload: string }
  | { type: 'NORMALIZE'; payload?: { forceDays?: boolean; forceHours?: boolean } }
  | { type: 'SET_FROM_MS'; payload: number };

// Helper functions
const normalizeTimeValue = (value: string, min = MIN_VALUE, max?: number): number => {
  const parsed = parseInt(value, 10) || 0;
  if (max !== undefined) {
    return Math.min(Math.max(parsed, min), max);
  }
  return Math.max(parsed, min);
};

const calculateMs = (days: number, hours: number): number => {
  return days * MILLISECONDS_IN_DAY + hours * MILLISECONDS_IN_HOUR;
};

// Reducer function for managing time state
const timeReducer = (state: TimeState, action: TimeAction): TimeState => {
  switch (action.type) {
    case 'SET_DAYS':
      return { ...state, days: action.payload, error: undefined };
    
    case 'SET_HOURS':
      return { ...state, hours: action.payload, error: undefined };
    
    case 'NORMALIZE': {
      const { forceDays = false, forceHours = false } = action.payload || {};
      const normalizedDays = forceDays ? String(normalizeTimeValue(state.days)) : state.days;
      const normalizedHours = forceHours ? String(normalizeTimeValue(state.hours, MIN_VALUE, MAX_HOURS)) : state.hours;
      
      return {
        days: normalizedDays,
        hours: normalizedHours,
        error: undefined
      };
    }
    
    case 'SET_FROM_MS': {
      const days = Math.floor(action.payload / MILLISECONDS_IN_DAY);
      const hours = Math.floor((action.payload % MILLISECONDS_IN_DAY) / MILLISECONDS_IN_HOUR);
      
      return {
        days: String(days),
        hours: String(hours),
        error: undefined
      };
    }
    
    default:
      return state;
  }
};

const TimeInput: React.FC<TimeInputProps> = ({ label, tooltip, valueMs, onChange }) => {
  // Calculate initial values
  const initialDays = Math.floor(valueMs / MILLISECONDS_IN_DAY);
  const initialHours = Math.floor((valueMs % MILLISECONDS_IN_DAY) / MILLISECONDS_IN_HOUR);
  
  // Use reducer for state management
  const [timeState, dispatch] = useReducer(timeReducer, {
    days: String(initialDays),
    hours: String(initialHours)
  });
  
  // Helper function to call onChange with calculated ms value
  const handleValueChange = (days: number, hours: number) => {
    onChange(calculateMs(days, hours));
  };
  
  // Update state if external value changes
  useEffect(() => {
    dispatch({ type: 'SET_FROM_MS', payload: valueMs });
  }, [valueMs]);
  
  // Handle days input change
  const handleDaysChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const inputValue = e.target.value;
    dispatch({ type: 'SET_DAYS', payload: inputValue });
    
    const parsedDays = parseInt(inputValue, 10);
    if (!isNaN(parsedDays)) {
      const parsedHours = normalizeTimeValue(timeState.hours, MIN_VALUE, MAX_HOURS);
      handleValueChange(parsedDays, parsedHours);
    }
  };
  
  // Handle hours input change
  const handleHoursChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const inputValue = e.target.value;
    dispatch({ type: 'SET_HOURS', payload: inputValue });
    
    const parsedHours = parseInt(inputValue, 10);
    if (!isNaN(parsedHours)) {
      // Consistently normalize hours before notifying parent
      const normalizedHours = normalizeTimeValue(inputValue, MIN_VALUE, MAX_HOURS);
      const parsedDays = normalizeTimeValue(timeState.days);
      handleValueChange(parsedDays, normalizedHours);
    }
  };
  
  // Handle blur events
  const handleDaysBlur = () => {
    dispatch({ type: 'NORMALIZE', payload: { forceDays: true } });
    const days = normalizeTimeValue(timeState.days);
    const hours = normalizeTimeValue(timeState.hours, MIN_VALUE, MAX_HOURS);
    onChange(calculateMs(days, hours));
  };
  
  const handleHoursBlur = () => {
    dispatch({ type: 'NORMALIZE', payload: { forceHours: true } });
    const days = normalizeTimeValue(timeState.days);
    const hours = normalizeTimeValue(timeState.hours, MIN_VALUE, MAX_HOURS);
    onChange(calculateMs(days, hours));
  };
  
  return (
    <div className="space-y-2">
      <div className="flex items-center space-x-2">
        <label className="block text-sm font-medium" id="time-input-label">{label}</label>
        <Tooltip content={tooltip}>
          <button 
            type="button" 
            className="inline-flex" 
            aria-label={`Information about ${label}`}
          >
            <InfoCircledIcon className="w-4 h-4 text-gray-400 hover:text-gray-600" />
          </button>
        </Tooltip>
      </div>
      <div className="flex space-x-2" role="group" aria-labelledby="time-input-label">
        <div className="flex-1">
          <label htmlFor="days-input" className="block text-xs">Days</label>
          <input
            id="days-input"
            type="number"
            value={timeState.days}
            onChange={handleDaysChange}
            onBlur={handleDaysBlur}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            min="0"
            step="1"
            aria-label="Days"
          />
        </div>
        <div className="flex-1">
          <label htmlFor="hours-input" className="block text-xs">Hours</label>
          <input
            id="hours-input"
            type="number"
            value={timeState.hours}
            onChange={handleHoursChange}
            onBlur={handleHoursBlur}
            className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
            min="0"
            max="24"
            step="1"
            aria-label="Hours"
          />
        </div>
      </div>
      {timeState.error && (
        <p className="text-sm text-red-500">{timeState.error}</p>
      )}
    </div>
  );
};

export default TimeInput;