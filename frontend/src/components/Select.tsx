// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { useState, useRef, useEffect } from "react";
import { ChevronDownIcon } from "@radix-ui/react-icons";

/**
 * A reusable custom Select component with enhanced styling and accessibility.
 */
export function Select({
  value,
  onChange,
  options,
  label,
  placeholder = "Select an option",
  disabled = false,
  className = "",
}: {
  value: string;
  onChange: (value: string) => void;
  options: { value: string; label: string }[];
  label?: string;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const [selectedLabel, setSelectedLabel] = useState("");
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Update the selected label when value or options change
  useEffect(() => {
    const selected = options.find(option => option.value === value);
    setSelectedLabel(selected ? selected.label : placeholder);
  }, [value, options, placeholder]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    };

    document.addEventListener("mousedown", handleClickOutside);
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, []);

  const handleSelect = (optionValue: string) => {
    onChange(optionValue);
    setIsOpen(false);
  };

  return (
    <div className="relative" ref={dropdownRef}>
      {label && (
        <label className="text-gray-300 text-xs font-medium mb-1.5 block">
          {label}
        </label>
      )}
      <div
        className={`px-3 py-2.5 rounded-lg bg-gray-800 text-white w-full border ${
          isOpen ? "border-blue-500 shadow-md shadow-blue-500/20" : "border-gray-700"
        } transition-all duration-200 ${className} flex justify-between items-center cursor-pointer ${
          disabled ? "opacity-50 cursor-not-allowed" : "hover:border-gray-500"
        }`}
        onClick={() => !disabled && setIsOpen(!isOpen)}
        role="combobox"
        aria-expanded={isOpen}
        aria-haspopup="listbox"
        aria-labelledby={label}
      >
        <span className={`${!value ? "text-gray-400" : "text-white"} font-medium`}>
          {selectedLabel}
        </span>
        <ChevronDownIcon 
          className={`transition-transform duration-200 ${isOpen ? "rotate-180" : ""} text-gray-400`} 
          width={18} 
          height={18}
        />
      </div>
      
      {isOpen && !disabled && (
        <div 
          className="absolute z-50 mt-2 w-full bg-gray-800 border border-gray-700 rounded-lg shadow-xl max-h-60 overflow-auto animate-fadeIn"
          role="listbox"
        >
          {options.map((option) => (
            <div
              key={option.value}
              className={`px-3 py-2.5 hover:bg-gray-700 cursor-pointer transition-colors duration-150 ${
                option.value === value ? "bg-blue-900/40 text-blue-300 font-medium" : "text-white"
              }`}
              onClick={() => handleSelect(option.value)}
              role="option"
              aria-selected={option.value === value}
            >
              {option.label}
            </div>
          ))}
          {options.length === 0 && (
            <div className="p-3 text-gray-400 text-center italic">No options available</div>
          )}
        </div>
      )}
    </div>
  );
}