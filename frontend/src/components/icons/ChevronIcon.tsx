import React from 'react';

interface ChevronIconProps {
  className?: string;
  direction?: 'up' | 'down';
}

const ChevronIcon: React.FC<ChevronIconProps> = ({ className, direction = 'down' }) => {
  const rotation = direction === 'up' ? 'rotate-180' : '';
  
  return (
    <svg 
      xmlns="http://www.w3.org/2000/svg" 
      className={`${className} ${rotation} transform`}
      fill="none" 
      viewBox="0 0 24 24" 
      stroke="currentColor"
    >
      <path 
        strokeLinecap="round" 
        strokeLinejoin="round" 
        strokeWidth={2} 
        d="M19 9l-7 7-7-7" 
      />
    </svg>
  );
};

export default ChevronIcon; 