import React from 'react';
import ReactMarkdown from 'markdown-to-jsx';

interface DescriptionProps {
  details: string;
}

const Description: React.FC<DescriptionProps> = ({ details }) => {
  return (
    <div className="prose px-6">
      <ReactMarkdown
        options={{
          overrides: {
            h1: { component: 'h1', props: { className: 'text-4xl font-bold my-4' } },
            h2: { component: 'h2', props: { className: 'text-3xl font-bold my-4' } },
            h3: { component: 'h3', props: { className: 'text-2xl font-bold my-3' } },
            h4: { component: 'h4', props: { className: 'text-xl font-bold my-2' } },
            h5: { component: 'h5', props: { className: 'text-lg font-bold my-2' } },
            h6: { component: 'h6', props: { className: 'text-base font-bold my-2' } },
          }
        }}
      >
        {details}
      </ReactMarkdown>
    </div>
  );
};

export default Description;