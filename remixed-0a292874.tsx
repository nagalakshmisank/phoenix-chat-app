import { useState } from 'react';

export default function PrzmaWeeksOfLife() {
  const [step, setStep] = useState(1);
  const [birthdate, setBirthdate] = useState('');
  const [stats, setStats] = useState(null);
  const [selectedLens, setSelectedLens] = useState('temporal');
  const [showHoverData, setShowHoverData] = useState(false);
  const [hoverWeek, setHoverWeek] = useState(null);
  const [perceptionData, setPerceptionData] = useState({});
  
  // Perception Intelligence Lenses based on PRZMA framework
  const perceptionLenses = {
    temporal: {
      name: 'Temporal Flow',
      description: 'Traditional past/present/future view',
      icon: '⏰'
    },
    presence: {
      name: 'Presence Intensity',
      description: 'Physical & emotional presence in spaces',
      icon: '🌍'
    },
    people: {
      name: 'Relationship Depth',
      description: 'Social connection and relationship quality',
      icon: '👥'
    },
    possessions: {
      name: 'Material Significance',
      description: 'Meaningful acquisitions and possessions',
      icon: '💎'
    },
    progress: {
      name: 'Growth Momentum',
      description: 'Personal and professional development',
      icon: '📈'
    },
    paths: {
      name: 'Life Direction',
      description: 'Clarity of purpose and path',
      icon: '🧭'
    },
    pursuits: {
      name: 'Engagement Energy',
      description: 'Activity engagement and passion',
      icon: '🔥'
    },
    purpose: {
      name: 'Meaning Depth',
      description: 'Life significance and fulfillment',
      icon: '⭐'
    },
    cultural: {
      name: 'Cultural Context',
      description: 'Societal and cultural influences',
      icon: '🌐'
    },
    emotional: {
      name: 'Emotional Resonance',
      description: 'Emotional intensity and well-being',
      icon: '💝'
    }
  };
  
  const calculateStats = (date) => {
    const birthDate = new Date(date);
    const today = new Date();
    
    const msInWeek = 1000 * 60 * 60 * 24 * 7;
    const weeksLived = Math.floor((today - birthDate) / msInWeek);
    const totalWeeks = 4160; // ~80 years
    const weeksRemaining = totalWeeks - weeksLived;
    const percentageLived = Math.round((weeksLived / totalWeeks) * 100);
    
    const msInDay = 1000 * 60 * 60 * 24;
    const daysLived = Math.floor((today - birthDate) / msInDay);
    
    return {
      weeksLived,
      totalWeeks,
      weeksRemaining,
      percentageLived,
      daysLived,
      birthDate
    };
  };
  
  // Generate perception data for demonstration
  const generatePerceptionData = (weeksLived) => {
    const data = {};
    
    for (let week = 0; week < weeksLived; week++) {
      // Simulate different life phases and their perception intensities
      const ageInYears = week / 52.14;
      
      data[week] = {
        presence: Math.random() * 0.6 + (ageInYears > 18 ? 0.4 : 0.2),
        people: Math.sin(ageInYears * 0.3) * 0.4 + 0.5 + Math.random() * 0.2,
        possessions: Math.min(ageInYears / 50 + Math.random() * 0.3, 1),
        progress: ageInYears < 25 ? 0.8 + Math.random() * 0.2 : 0.3 + Math.random() * 0.4,
        paths: Math.abs(Math.sin(ageInYears * 0.1)) * 0.7 + 0.3,
        pursuits: Math.random() * 0.8 + 0.2,
        purpose: ageInYears > 30 ? 0.6 + Math.random() * 0.4 : 0.2 + Math.random() * 0.5,
        cultural: Math.random() * 0.5 + 0.3,
        emotional: Math.sin(week * 0.1) * 0.3 + 0.6 + Math.random() * 0.2
      };
    }
    
    return data;
  };

  const handleSubmit = () => {
    const calculatedStats = calculateStats(birthdate);
    setStats(calculatedStats);
    setPerceptionData(generatePerceptionData(calculatedStats.weeksLived));
    setStep(2);
  };

  const getWeekColor = (weekNumber) => {
    if (!stats || !perceptionData[weekNumber]) {
      if (weekNumber < stats?.weeksLived) return 'bg-gray-400';
      if (weekNumber === stats?.weeksLived) return 'bg-blue-500';
      return 'bg-gray-200';
    }
    
    if (selectedLens === 'temporal') {
      if (weekNumber < stats.weeksLived) return 'bg-gray-800';
      if (weekNumber === stats.weeksLived) return 'bg-blue-500';
      return 'bg-gray-200';
    }
    
    const intensity = perceptionData[weekNumber][selectedLens] || 0;
    
    // Color mapping based on perception intensity
    const colorMaps = {
      presence: ['bg-green-100', 'bg-green-300', 'bg-green-500', 'bg-green-700', 'bg-green-900'],
      people: ['bg-pink-100', 'bg-pink-300', 'bg-pink-500', 'bg-pink-700', 'bg-pink-900'],
      possessions: ['bg-amber-100', 'bg-amber-300', 'bg-amber-500', 'bg-amber-700', 'bg-amber-900'],
      progress: ['bg-blue-100', 'bg-blue-300', 'bg-blue-500', 'bg-blue-700', 'bg-blue-900'],
      paths: ['bg-purple-100', 'bg-purple-300', 'bg-purple-500', 'bg-purple-700', 'bg-purple-900'],
      pursuits: ['bg-red-100', 'bg-red-300', 'bg-red-500', 'bg-red-700', 'bg-red-900'],
      purpose: ['bg-yellow-100', 'bg-yellow-300', 'bg-yellow-500', 'bg-yellow-700', 'bg-yellow-900'],
      cultural: ['bg-indigo-100', 'bg-indigo-300', 'bg-indigo-500', 'bg-indigo-700', 'bg-indigo-900'],
      emotional: ['bg-rose-100', 'bg-rose-300', 'bg-rose-500', 'bg-rose-700', 'bg-rose-900']
    };
    
    const colorScale = colorMaps[selectedLens] || colorMaps.progress;
    const colorIndex = Math.min(Math.floor(intensity * 5), 4);
    
    return colorScale[colorIndex];
  };
  
  const getPerceptionDescription = (weekNumber) => {
    if (!perceptionData[weekNumber]) return "No data available";
    
    const intensity = perceptionData[weekNumber][selectedLens] || 0;
    const ageAtWeek = Math.floor(weekNumber / 52.14);
    
    const descriptions = {
      presence: intensity > 0.7 ? "High presence & awareness" : intensity > 0.4 ? "Moderate presence" : "Lower presence",
      people: intensity > 0.7 ? "Rich social connections" : intensity > 0.4 ? "Balanced relationships" : "Quieter social period",
      possessions: intensity > 0.7 ? "Significant acquisitions" : intensity > 0.4 ? "Moderate material focus" : "Minimal material focus",
      progress: intensity > 0.7 ? "Rapid growth period" : intensity > 0.4 ? "Steady development" : "Plateau or reflection",
      paths: intensity > 0.7 ? "Clear direction & purpose" : intensity > 0.4 ? "Exploring options" : "Uncertain direction",
      pursuits: intensity > 0.7 ? "High engagement & passion" : intensity > 0.4 ? "Active involvement" : "Low activity period",
      purpose: intensity > 0.7 ? "Deep meaning & fulfillment" : intensity > 0.4 ? "Growing purpose" : "Seeking meaning",
      cultural: intensity > 0.7 ? "Strong cultural influence" : intensity > 0.4 ? "Moderate cultural impact" : "Limited cultural engagement",
      emotional: intensity > 0.7 ? "High emotional intensity" : intensity > 0.4 ? "Balanced emotional state" : "Lower emotional energy"
    };
    
    return `Week ${weekNumber + 1} (Age ${ageAtWeek}): ${descriptions[selectedLens]}`;
  };

  const renderWeekGrid = () => {
    if (!stats) return null;
    
    const rows = [];
    const weeksPerRow = 52;
    const totalRows = Math.ceil(stats.totalWeeks / weeksPerRow);
    
    for (let row = 0; row < totalRows; row++) {
      const weekCells = [];
      for (let col = 0; col < weeksPerRow; col++) {
        const weekNumber = row * weeksPerRow + col;
        if (weekNumber < stats.totalWeeks) {
          const cellClass = `w-2 h-2 m-0.5 rounded-sm transition-all cursor-pointer ${getWeekColor(weekNumber)} hover:scale-125`;
          
          weekCells.push(
            <div 
              key={weekNumber}
              className={cellClass}
              onMouseEnter={() => {
                setHoverWeek(weekNumber);
                setShowHoverData(true);
              }}
              onMouseLeave={() => setShowHoverData(false)}
            />
          );
        }
      }
      
      // Age markers every 10 years
      const yearLabel = row * weeksPerRow === 0 ? '0' : Math.floor((row * weeksPerRow) / 52.14).toString();
      
      rows.push(
        <div key={row} className="flex items-center">
          <div className="w-6 text-xs text-gray-400 text-right mr-2">
            {row % 10 === 0 && row < 80 ? yearLabel : ''}
          </div>
          <div className="flex">
            {weekCells}
          </div>
        </div>
      );
    }
    
    return (
      <div className="mt-8 bg-white p-6 rounded-md shadow-sm">
        <div className="flex justify-between items-center mb-6">
          <h2 className="text-lg font-normal text-gray-800">
            Life through {perceptionLenses[selectedLens].name} lens {perceptionLenses[selectedLens].icon}
          </h2>
          <select 
            value={selectedLens} 
            onChange={(e) => setSelectedLens(e.target.value)}
            className="px-3 py-1 border border-gray-300 rounded-md text-sm"
          >
            {Object.entries(perceptionLenses).map(([key, lens]) => (
              <option key={key} value={key}>{lens.icon} {lens.name}</option>
            ))}
          </select>
        </div>
        
        <p className="text-sm text-gray-600 mb-4">{perceptionLenses[selectedLens].description}</p>
        
        <div className="flex flex-col space-y-1">
          {rows}
        </div>
        
        {showHoverData && hoverWeek !== null && (
          <div className="mt-4 p-3 bg-gray-50 rounded text-sm text-gray-700 border-l-4 border-blue-400">
            {getPerceptionDescription(hoverWeek)}
          </div>
        )}
        
        <div className="mt-6 text-xs text-gray-500">
          Each dot represents one week. Hover over any week to see perception details.
        </div>
      </div>
    );
  };

  const renderPerceptionInsights = () => {
    if (!stats || !perceptionData) return null;
    
    // Calculate averages for each dimension
    const dimensionAverages = {};
    Object.keys(perceptionLenses).forEach(lens => {
      if (lens !== 'temporal') {
        let sum = 0;
        let count = 0;
        Object.values(perceptionData).forEach(weekData => {
          if (weekData[lens] !== undefined) {
            sum += weekData[lens];
            count++;
          }
        });
        dimensionAverages[lens] = count > 0 ? sum / count : 0;
      }
    });
    
    return (
      <div className="mt-8 bg-white p-6 rounded-md shadow-sm">
        <h2 className="text-lg font-normal mb-4 text-gray-800">Perception Intelligence Summary</h2>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {Object.entries(dimensionAverages).map(([lens, average]) => (
            <div key={lens} className="flex items-center justify-between p-3 bg-gray-50 rounded">
              <span className="text-sm font-medium text-gray-700">
                {perceptionLenses[lens].icon} {perceptionLenses[lens].name}
              </span>
              <div className="flex items-center">
                <div className="w-24 bg-gray-200 rounded-full h-2 mr-2">
                  <div 
                    className="bg-blue-500 h-2 rounded-full transition-all" 
                    style={{width: `${average * 100}%`}}
                  ></div>
                </div>
                <span className="text-xs text-gray-500">{Math.round(average * 100)}%</span>
              </div>
            </div>
          ))}
        </div>
        
        <div className="mt-6 p-4 bg-blue-50 rounded-md">
          <h3 className="font-medium text-blue-900 mb-2">Life Phase Analysis</h3>
          <p className="text-sm text-blue-800">
            Your perception intelligence shows strongest patterns in{' '}
            <span className="font-medium">
              {Object.entries(dimensionAverages)
                .sort(([,a], [,b]) => b - a)
                .slice(0, 2)
                .map(([lens]) => perceptionLenses[lens].name)
                .join(' and ')}
            </span>
            , indicating these are core dimensions of your life experience.
          </p>
        </div>
      </div>
    );
  };

  const handleReset = () => {
    setBirthdate('');
    setStats(null);
    setPerceptionData({});
    setStep(1);
    setSelectedLens('temporal');
  };

  return (
    <div className="min-h-screen bg-gray-50 p-6 pt-16">
      <div className="max-w-5xl mx-auto">
        <div className="text-center mb-8">
          <h1 className="text-3xl font-normal text-gray-800 mb-2">PRZMA Life in Weeks</h1>
          <p className="text-gray-600">Visualize your life through multiple perception intelligence lenses</p>
        </div>
        
        {step === 1 ? (
          <div className="max-w-md mx-auto bg-white p-6 rounded-md shadow-sm">
            <h2 className="text-lg font-normal mb-4 text-gray-800">When were you born?</h2>
            <div>
              <input
                type="date"
                className="w-full p-3 border border-gray-300 rounded-md mb-4 text-gray-800"
                value={birthdate}
                onChange={(e) => setBirthdate(e.target.value)}
                required
              />
              <button
                onClick={handleSubmit}
                className="w-full bg-gray-800 text-white py-3 rounded-md hover:bg-gray-700 transition-colors"
                disabled={!birthdate}
              >
                Generate Perception Intelligence View
              </button>
            </div>
            
            <div className="mt-6 p-4 bg-blue-50 rounded-md">
              <h3 className="font-medium text-blue-900 mb-2">Available Perception Lenses:</h3>
              <div className="grid grid-cols-2 gap-2 text-xs text-blue-800">
                {Object.entries(perceptionLenses).map(([key, lens]) => (
                  <div key={key} className="flex items-center">
                    <span className="mr-1">{lens.icon}</span>
                    <span>{lens.name}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        ) : (
          <>
            {renderWeekGrid()}
            {renderPerceptionInsights()}
            <div className="text-center mt-8">
              <button
                onClick={handleReset}
                className="bg-gray-200 text-gray-800 px-6 py-2 rounded-md hover:bg-gray-300 transition-colors"
              >
                Start Over
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
