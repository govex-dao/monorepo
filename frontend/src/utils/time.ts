  // Format periods from milliseconds to hours and minutes
  export const formatPeriod = (periodMs: string) => {
    const totalMinutes = Number(periodMs) / 1000 / 60;
    const hours = Math.floor(totalMinutes / 60);
    const minutes = Math.floor(totalMinutes % 60);

    if (hours > 0) {
      return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
    } else {
      return `${minutes}m`;
    }
  };