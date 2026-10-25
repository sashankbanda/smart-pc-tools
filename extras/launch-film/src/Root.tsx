import '@fontsource-variable/inter';
import React from 'react';
import { Composition, continueRender, delayRender } from 'remotion';
import { Film } from './Film';
import { DURATION, FPS } from './timeline';

// Wait for Inter before the first frame, so no frame is drawn in a fallback font.
const fontsReady = delayRender('Loading Inter');
Promise.all([
  document.fonts.load('600 64px "Inter Variable"'),
  document.fonts.load('500 30px "Inter Variable"'),
]).then(() => continueRender(fontsReady), () => continueRender(fontsReady));

export const Root: React.FC = () => (
  <>
    <Composition id="Film" component={Film} durationInFrames={Math.round(DURATION * FPS)} fps={FPS} width={1920} height={1080} />
    <Composition id="FilmVertical" component={Film} durationInFrames={Math.round(DURATION * FPS)} fps={FPS} width={1080} height={1920} />
  </>
);
