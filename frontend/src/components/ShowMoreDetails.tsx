import { Dispatch, SetStateAction } from "react";
import ChevronIcon from "./icons/ChevronIcon";

interface Props {
  show: boolean;
  setShow: Dispatch<SetStateAction<boolean>>;
  title: string;
}

export function ShowMoreDetails(props: Props) {
  const { show, setShow, title } = props;
  return (
    <button
      onClick={() => setShow((p) => !p)}
      className="text-xs text-gray-400 hover:text-white flex items-center transition-colors duration-200 px-2 py-0.5 rounded hover:bg-gray-800"
    >
      {show ? (
        <>
          <ChevronIcon className="h-3 w-3 mr-1" direction="down" />
          Hide {title}
        </>
      ) : (
        <>
          <ChevronIcon className="h-3 w-3 mr-1" direction="up" />
          Show {title}
        </>
      )}
    </button>
  );
}
