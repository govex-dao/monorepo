import { Dispatch, SetStateAction } from "react"

interface Props {
    show: boolean, 
    setShow: Dispatch<SetStateAction<boolean>>,
    title: string
}

export function ShowMoreDetails(props: Props) {
    const {show, setShow, title} = props
    return (<button
        onClick={() => setShow((p) =>!p)}
        className="text-xs text-gray-400 hover:text-white flex items-center transition-colors duration-200 px-2 py-0.5 rounded hover:bg-gray-800"
    >
        {show ? (
            <>
                <svg xmlns="http://www.w3.org/2000/svg" className="h-3 w-3 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
                </svg>
                Hide {title}
            </>
        ) : (
            <>
                <svg xmlns="http://www.w3.org/2000/svg" className="h-3 w-3 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 15l7-7 7 7" />
                </svg>
                Show {title}
            </>
        )}
    </button>)
}