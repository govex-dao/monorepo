import React from "react";
import { InfoCircledIcon } from "@radix-ui/react-icons";

interface FormFieldProps {
  label: string;
  name: string;
  value: string;
  onChange: (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
  ) => void;
  tooltip: string;
  isTextArea?: boolean;
  placeholder?: string;
}

export const FormField: React.FC<FormFieldProps> = ({
  label,
  name,
  value,
  onChange,
  tooltip,
  isTextArea = false,
  placeholder = "",
}) => (
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
    {isTextArea ? (
      <textarea
        name={name}
        value={value}
        onChange={onChange}
        className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500 min-h-[100px]"
        placeholder={placeholder}
        required
      />
    ) : (
      <input
        type="text"
        name={name}
        value={value}
        onChange={onChange}
        className="w-full p-2 border rounded focus:ring-2 focus:ring-blue-500"
        placeholder={placeholder}
        required
      />
    )}
  </div>
);
