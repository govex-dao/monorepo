import React from "react";

interface MessageDecoderProps {
  messages: string[];
}

const MessageDecoder: React.FC<MessageDecoderProps> = ({ messages }) => {
  return (
    <div className="space-y-2">
      {messages.map((message, index) => (
        <div key={index} className="bg-gray-900 p-3 rounded">
          <p className="text-gray-200">{message}</p>
        </div>
      ))}
    </div>
  );
};

export default MessageDecoder;
