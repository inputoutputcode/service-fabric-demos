﻿// ------------------------------------------------------------
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License (MIT). See License.txt in the repo root for license information.
// ------------------------------------------------------------

using System;
using System.Fabric.Description;
using System.Runtime.InteropServices;
using System.Security;

namespace FabricObserver.Observers.MachineInfoModel
{
    public class ConfigurationSetting<T>
    {
        /// <summary>
        /// Initializes a new instance of the <see cref="ConfigurationSetting{T}"/> class.
        /// </summary>
        /// <param name="configurationSettings">The settings instance.</param>
        /// <param name="configurationSectionName">The section name.</param>
        /// <param name="settingName">The setting name.</param>
        /// <param name="defaultValue">The default value.</param>
        public ConfigurationSetting(
            ConfigurationSettings configurationSettings,
            string configurationSectionName,
            string settingName,
            T defaultValue)
            : this(
                configurationSectionName,
                settingName,
                defaultValue,
                true)
        {
            ConfigurationSettings = configurationSettings;
        }

        /// <summary>
        /// Initializes a new instance of the <see cref="ConfigurationSetting{T}"/> class.
        /// </summary>
        /// <param name="configurationSectionName">name.</param>
        /// <param name="settingName"> Name of the setting. </param>
        /// <param name="defaultValue"> Default value of the setting if it does not exist in the ACS. </param>
        /// <param name="enableTracing"> Whether to log the value of the setting when it is read from the ACS. </param>
        private ConfigurationSetting(
            string configurationSectionName,
            string settingName,
            T defaultValue,
            bool enableTracing)
        {
            SettingName = settingName;
            DefaultValue = defaultValue;
            ValueSpecified = false;
            DisableTracing = !enableTracing;
            ConfigurationSectionName = configurationSectionName;
        }

        /// <summary>
        ///   Gets or sets a value indicating whether tracing should be used when accessing this setting.
        /// </summary>
        /// <remarks>
        ///   This property allows the tracing subsystem itself to use configuration settings, where infinite recursion might otherwise occur.
        /// </remarks>
        public bool DisableTracing
        {
            get; set;
        }

        public virtual T Value
        {
            get
            {
                if (ValueSpecified)
                {
                    return Value1;
                }

                Value1 = DefaultValue;
                var appConfigValue = GetConfigurationSetting(SettingName);

                if (appConfigValue != null)
                {
                    Value1 = !TryParse(appConfigValue, out T val) ? DefaultValue : val;
                }

                ValueSpecified = true;

                // This is ALWAYS the ACS value of the setting (never overwritten)
                return Value1;
            }
        }

        protected string ConfigurationSectionName
        {
            get;
        }

        protected ConfigurationSettings ConfigurationSettings
        {
            get;
        }

        protected T DefaultValue
        {
            get;
        }

        protected string SettingName
        {
            get;
        }

        protected T Value1
        {
            get; set;
        }

        protected bool ValueSpecified
        {
            get; set;
        }

        /// <summary>
        /// Try to parse the string and return an object of the given type.
        /// </summary>
        /// <param name="value"> String to be parsed. </param>
        /// <param name="type"> Type of result. </param>
        /// <returns> Result of parsing the string. </returns>
        public object Parse(string value, Type type)
        {
            if (string.IsNullOrEmpty(value)
            || type == null)
            {
                return null;
            }

            try
            {
                if (type == typeof(string))
                {
                    return value;
                }

                if (type == typeof(bool))
                {
                    return bool.Parse(value);
                }

                if (type == typeof(int))
                {
                    return int.Parse(value);
                }

                if (type == typeof(double))
                {
                    return double.Parse(value);
                }

                if (type == typeof(Guid))
                {
                    return Guid.Parse(value);
                }

                if (type == typeof(Uri))
                {
                    return new Uri(value);
                }

                if (type == typeof(SecureString))
                {
                    return StringToSecureString(value);
                }

                if (type.IsEnum)
                {
                    return Enum.Parse(type, value, true);
                }

                if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(Nullable<>))
                {
                    return Parse(value, type.GetGenericArguments()[0]);
                }

                if (type.IsArray && type.GetElementType() == typeof(byte))
                {
                    return Convert.FromBase64String(value);
                }

                var parseMethod = type.GetMethod("Parse", new[] { typeof(string) });

                return parseMethod?.Invoke(null, new object[] { value });
            }
            catch (ArgumentException)
            {
                return null;
            }
            catch (FormatException)
            {
                return null;
            }
        }

        /// <summary>
        ///   Parse the string and return a typed value.
        /// </summary>
        /// <typeparam name="TU"> Value type. </typeparam>
        /// <param name="valueString"> Value in string format. </param>
        /// <param name="value"> Result of parsing. </param>
        /// <returns> True if succeeds. </returns>
        public bool TryParse<TU>(string valueString, out TU value)
        {
            var result = Parse(valueString, typeof(TU));
            if (result == null)
            {
                value = default;
                return false;
            }

            value = (TU)result;
            return true;
        }

        public static char[] SecureStringToCharArray(SecureString secureString)
        {
            if (secureString == null)
            {
                return null;
            }

            char[] charArray = new char[secureString.Length];
            var ptr = Marshal.SecureStringToGlobalAllocUnicode(secureString);
            try
            {
                Marshal.Copy(ptr, charArray, 0, secureString.Length);
            }
            finally
            {
                Marshal.ZeroFreeGlobalAllocUnicode(ptr);
            }

            return charArray;
        }

        public static SecureString StringToSecureString(string value)
        {
            if (value == null)
            {
                return null;
            }

            var secureString = new SecureString();

            foreach (var c in value)
            {
                secureString.AppendChar(c);
            }

            return secureString;
        }

        /// <summary>
        /// Get Windows Fabric Settings from config.
        /// </summary>
        /// <param name="parameterName">Return settings for the parameter name.</param>
        /// <returns>string.</returns>
        public string GetConfigurationSetting(string parameterName)
        {
            if (string.IsNullOrEmpty(parameterName) || ConfigurationSettings == null)
            {
                return null;
            }

            if (!ConfigurationSettings.Sections.Contains(ConfigurationSectionName)
                || ConfigurationSettings.Sections[ConfigurationSectionName] == null)
            {
                return null;
            }

            if (!ConfigurationSettings.Sections[ConfigurationSectionName].Parameters.Contains(parameterName))
            {
                return null;
            }

            string parameterValue = ConfigurationSettings.Sections[ConfigurationSectionName].Parameters[parameterName].Value;

            if (!ConfigurationSettings.Sections[ConfigurationSectionName].Parameters[parameterName]
                .IsEncrypted || string.IsNullOrEmpty(parameterValue))
            {
                return parameterValue;
            }

            var paramValueAsCharArray = SecureStringToCharArray(
                ConfigurationSettings.Sections[ConfigurationSectionName].Parameters[parameterName].DecryptValue());

            return new string(paramValueAsCharArray);
        }
    }
}
