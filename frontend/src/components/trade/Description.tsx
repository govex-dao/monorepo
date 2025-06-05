import React from "react";
import MarkdownRenderer from "../MarkdownRenderer";

interface DescriptionProps {
  details: string;
}

const Description: React.FC<DescriptionProps> = ({ details }) => {
  return <MarkdownRenderer content={details} />;
};

export default Description;
