module.exports = function (api) {
  api.cache(true);
  return {
    presets: ['babel-preset-expo'],
    // react-native-worklets/plugin must stay LAST (required by Reanimated 4,
    // which react-native-gesture-handler builds on).
    plugins: ['react-native-worklets/plugin'],
  };
};
